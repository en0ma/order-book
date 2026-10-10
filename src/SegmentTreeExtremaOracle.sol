// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IExtremaOracle} from "./interfaces/IExtremaOracle.sol";

/// @title SegmentTreeExtremaOracle
/// @notice Bounded on-chain mark history with O(log N) append and range-extrema queries.
/// @dev Stores the most recent 4096 observations in a ring-backed segment tree.
///      Observations older than the retained window expire. The updater is expected
///      to be the authoritative mark publisher; trigger verification itself is permissionless.
contract SegmentTreeExtremaOracle is IExtremaOracle {
    uint256 public constant CAPACITY = 4096;
    uint256 internal constant MASK = CAPACITY - 1;
    uint256 internal constant TREE_BASE = CAPACITY;

    address public immutable owner;
    address public updater;
    address public pendingUpdater;
    uint32 public immutable maxAge;

    uint16 internal _markTick;
    uint48 public lastObservationTime;
    uint64 public override currentObservationId;

    // Packed node uses two 17-bit (tick + 1) fields so zero is an empty sentinel.
    mapping(uint256 => uint64) internal _tree;

    error Unauthorized();
    error ZeroObservation();
    error ObservationExpired();
    error InvalidObservation();
    error StaleObservation();

    event ObservationRecorded(uint64 indexed observationId, uint16 tick);
    event UpdaterTransferProposed(address indexed currentUpdater, address indexed pendingUpdater);
    event UpdaterTransferCancelled(address indexed pendingUpdater);
    event UpdaterTransferred(address indexed previousUpdater, address indexed newUpdater);

    constructor(address updater_, uint16 initialTick, uint32 maxAge_) {
        if (updater_ == address(0)) revert Unauthorized();
        if (maxAge_ == 0) revert InvalidObservation();

        owner = msg.sender;
        updater = updater_;
        maxAge = maxAge_;
        _record(initialTick, uint48(block.timestamp));
    }

    function proposeUpdater(address nextUpdater) external {
        if (msg.sender != owner || nextUpdater == address(0) || nextUpdater == updater) {
            revert Unauthorized();
        }
        pendingUpdater = nextUpdater;
        emit UpdaterTransferProposed(updater, nextUpdater);
    }

    function cancelUpdaterTransfer() external {
        if (msg.sender != owner) revert Unauthorized();
        address pending = pendingUpdater;
        if (pending == address(0)) revert Unauthorized();
        delete pendingUpdater;
        emit UpdaterTransferCancelled(pending);
    }

    function acceptUpdater() external {
        if (msg.sender != pendingUpdater || msg.sender == address(0)) revert Unauthorized();
        address previous = updater;
        updater = msg.sender;
        delete pendingUpdater;
        emit UpdaterTransferred(previous, msg.sender);
    }

    function markTick() external view override returns (uint16) {
        _requireFresh();
        return _markTick;
    }

    function record(uint16 tick) external returns (uint64 observationId) {
        if (msg.sender != updater) revert Unauthorized();
        observationId = _record(tick, uint48(block.timestamp));
    }

    function recordAt(uint16 tick, uint48 observationTime)
        external
        returns (uint64 observationId)
    {
        if (msg.sender != updater) revert Unauthorized();
        if (
            uint256(observationTime) > block.timestamp
                || (
                    observationTime < lastObservationTime
                        && (
                            currentObservationId != 1
                                || block.timestamp - uint256(observationTime) > maxAge
                        )
                )
        ) revert InvalidObservation();
        observationId = _record(tick, observationTime);
    }

    function highLowSince(uint64 observationId)
        external
        view
        override
        returns (uint16 highTick, uint16 lowTick)
    {
        _requireFresh();
        uint64 current = currentObservationId;
        if (observationId == 0) revert ZeroObservation();
        if (observationId > current) revert InvalidObservation();

        uint64 oldest = current > CAPACITY ? current - uint64(CAPACITY) + 1 : 1;
        if (observationId < oldest) revert ObservationExpired();

        uint256 start = uint256(observationId - 1) & MASK;
        uint256 end = uint256(current - 1) & MASK;

        uint64 packed;
        if (start <= end) {
            packed = _query(start, end);
        } else {
            packed = _merge(_query(start, CAPACITY - 1), _query(0, end));
        }

        highTick = uint16(((packed >> 17) & 0x1ffff) - 1);
        lowTick = uint16((packed & 0x1ffff) - 1);
    }

    function _record(uint16 tick, uint48 observationTime)
        internal
        returns (uint64 observationId)
    {
        unchecked {
            observationId = currentObservationId + 1;
        }
        currentObservationId = observationId;
        _markTick = tick;
        lastObservationTime = observationTime;

        uint256 index = uint256(observationId - 1) & MASK;
        uint256 node = TREE_BASE + index;
        _tree[node] = _pack(tick, tick);

        while (node > 1) {
            node >>= 1;
            _tree[node] = _merge(_tree[node << 1], _tree[(node << 1) | 1]);
        }

        emit ObservationRecorded(observationId, tick);
    }

    function _query(uint256 leftIndex, uint256 rightIndex)
        internal
        view
        returns (uint64 result)
    {
        uint256 left = TREE_BASE + leftIndex;
        uint256 right = TREE_BASE + rightIndex;

        while (left <= right) {
            if ((left & 1) == 1) {
                result = _merge(result, _tree[left]);
                unchecked {
                    ++left;
                }
            }

            if ((right & 1) == 0) {
                result = _merge(result, _tree[right]);
                if (right == 0) break;
                unchecked {
                    --right;
                }
            }

            left >>= 1;
            right >>= 1;
        }
    }

    function _merge(uint64 a, uint64 b) internal pure returns (uint64) {
        if (a == 0) return b;
        if (b == 0) return a;

        uint16 highA = uint16(((a >> 17) & 0x1ffff) - 1);
        uint16 lowA = uint16((a & 0x1ffff) - 1);
        uint16 highB = uint16(((b >> 17) & 0x1ffff) - 1);
        uint16 lowB = uint16((b & 0x1ffff) - 1);

        uint16 high = highA > highB ? highA : highB;
        uint16 low = lowA < lowB ? lowA : lowB;
        return _pack(high, low);
    }

    function _pack(uint16 high, uint16 low) internal pure returns (uint64) {
        uint64 encodedHigh = uint64(high) + 1;
        uint64 encodedLow = uint64(low) + 1;
        return (encodedHigh << 17) | encodedLow;
    }

    function _requireFresh() internal view {
        if (block.timestamp > uint256(lastObservationTime) + uint256(maxAge)) {
            revert StaleObservation();
        }
    }
}

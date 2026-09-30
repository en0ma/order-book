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

    address public immutable updater;
    uint16 public override markTick;
    uint64 public override currentObservationId;

    // Packed node: high in bits [31:16], low in [15:0].
    mapping(uint256 => uint32) internal _tree;

    error Unauthorized();
    error ZeroObservation();
    error ObservationExpired();
    error InvalidObservation();

    event ObservationRecorded(uint64 indexed observationId, uint16 tick);

    constructor(address updater_, uint16 initialTick) {
        if (updater_ == address(0)) revert Unauthorized();
        updater = updater_;
        _record(initialTick);
    }

    function record(uint16 tick) external returns (uint64 observationId) {
        if (msg.sender != updater) revert Unauthorized();
        observationId = _record(tick);
    }

    function highLowSince(uint64 observationId)
        external
        view
        override
        returns (uint16 highTick, uint16 lowTick)
    {
        uint64 current = currentObservationId;
        if (observationId == 0) revert ZeroObservation();
        if (observationId > current) revert InvalidObservation();

        uint64 oldest = current > CAPACITY ? current - uint64(CAPACITY) + 1 : 1;
        if (observationId < oldest) revert ObservationExpired();

        uint256 start = uint256(observationId - 1) & MASK;
        uint256 end = uint256(current - 1) & MASK;

        uint32 packed;
        if (start <= end) {
            packed = _query(start, end);
        } else {
            packed = _merge(_query(start, CAPACITY - 1), _query(0, end));
        }

        highTick = uint16(packed >> 16);
        lowTick = uint16(packed);
    }

    function _record(uint16 tick) internal returns (uint64 observationId) {
        unchecked {
            observationId = currentObservationId + 1;
        }
        currentObservationId = observationId;
        markTick = tick;

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
        returns (uint32 result)
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

    function _merge(uint32 a, uint32 b) internal pure returns (uint32) {
        if (a == 0) return b;
        if (b == 0) return a;

        uint16 highA = uint16(a >> 16);
        uint16 lowA = uint16(a);
        uint16 highB = uint16(b >> 16);
        uint16 lowB = uint16(b);

        uint16 high = highA > highB ? highA : highB;
        uint16 low = lowA < lowB ? lowA : lowB;
        return _pack(high, low);
    }

    function _pack(uint16 high, uint16 low) internal pure returns (uint32) {
        return (uint32(high) << 16) | uint32(low);
    }
}

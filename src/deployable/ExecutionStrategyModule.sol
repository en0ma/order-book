// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";

interface IAdvancedStrategyGateway {
    function strategyReserveExposure(address account, IOrderBookCore.Side side, uint96 lots)
        external returns (uint16 riskCeilingTick);
    function strategyReleaseExposure(address account, IOrderBookCore.Side side, uint96 lots)
        external;
    function strategyTake(
        address account,
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 lots,
        bool preReserved
    ) external returns (uint96 filledLots);
    function strategyAddLiquidity(
        address account,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots,
        uint16 riskCeilingTick
    ) external returns (uint128 shares);
    function strategySettle(address account, IOrderBookCore.Side side, uint16 tick)
        external returns (uint96 filledLots);
    function strategyRemoveLockedShares(
        address account,
        IOrderBookCore.Side side,
        uint16 tick,
        uint32 generation,
        uint128 shares
    ) external returns (uint96 removedLots);
}

/// @title ExecutionStrategyModule
/// @notice Optional iceberg, scheduled/TWAP and mark-pegged execution strategies.
/// @dev Strategy actions route through AdvancedOrderModule so Core keeps one privileged module boundary.
contract ExecutionStrategyModule {
    enum Kind { None, Iceberg, TWAP, Pegged }

    struct Strategy {
        address owner;
        uint96 remainingLots;
        uint96 sliceLots;
        uint64 nextExecution;
        uint64 interval;
        uint64 deadline;
        uint16 limitTick;
        int16 pegOffsetTicks;
        IOrderBookCore.Side side;
        Kind kind;
        bool active;
    }

    struct RestingSlice {
        uint128 shares;
        uint32 generation;
        uint16 tick;
    }

    error Unauthorized();
    error InvalidStrategy();
    error StrategyInactive();
    error TooEarly();
    error StrategyExpired();
    error QuoteContaminated();
    error NothingToDo();

    IOrderBookCore public immutable core;
    IAdvancedStrategyGateway public immutable gateway;
    uint64 public nextStrategyId = 1;

    mapping(uint64 => Strategy) public strategies;
    mapping(uint64 => RestingSlice) public restingSlices;
    mapping(address => uint32) public activeStrategyCount;

    event IcebergPlaced(
        uint64 indexed strategyId,
        address indexed owner,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 totalLots,
        uint96 displayLots
    );
    event IcebergRefreshed(
        uint64 indexed strategyId,
        uint96 newlyFilledLots,
        uint96 visibleLots,
        uint96 remainingLots
    );
    event TWAPPlaced(
        uint64 indexed strategyId,
        address indexed owner,
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 totalLots,
        uint96 sliceLots,
        uint64 startTime,
        uint64 interval,
        uint64 deadline
    );
    event TWAPSliceExecuted(
        uint64 indexed strategyId,
        uint96 requestedLots,
        uint96 filledLots,
        uint96 remainingLots,
        uint64 nextExecution
    );
    event PeggedPlaced(
        uint64 indexed strategyId,
        address indexed owner,
        IOrderBookCore.Side side,
        int16 offsetTicks,
        uint16 priceBoundTick,
        uint96 lots,
        uint16 initialTick
    );
    event PeggedRepriced(
        uint64 indexed strategyId,
        uint16 previousTick,
        uint16 nextTick,
        uint96 newlyFilledLots,
        uint96 remainingLots
    );
    event StrategyCancelled(uint64 indexed strategyId, uint96 remainingLots);
    event StrategyCompleted(uint64 indexed strategyId);

    constructor(address core_, address gateway_) {
        if (core_ == address(0) || gateway_ == address(0)) revert Unauthorized();
        core = IOrderBookCore(core_);
        gateway = IAdvancedStrategyGateway(gateway_);
    }

    function placeIceberg(
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 totalLots,
        uint96 displayLots
    ) external returns (uint64 strategyId) {
        if (totalLots == 0 || displayLots == 0 || displayLots > totalLots) {
            revert InvalidStrategy();
        }
        _requireCleanQuote(msg.sender, side, tick);

        strategyId = nextStrategyId++;
        Strategy storage s = strategies[strategyId];
        s.owner = msg.sender;
        s.remainingLots = totalLots;
        s.sliceLots = displayLots;
        s.limitTick = tick;
        s.side = side;
        s.kind = Kind.Iceberg;
        s.active = true;
        activeStrategyCount[msg.sender] += 1;

        _addRestingSlice(strategyId, s, _min(displayLots, totalLots), tick);
        emit IcebergPlaced(strategyId, msg.sender, side, tick, totalLots, displayLots);
    }

    function refreshIceberg(uint64 strategyId)
        external
        returns (uint96 newlyFilledLots, uint96 visibleLots)
    {
        Strategy storage s = _active(strategyId, Kind.Iceberg);
        _requireExclusive(strategyId, s);

        newlyFilledLots = gateway.strategySettle(s.owner, s.side, s.limitTick);
        _consumeFilled(strategyId, s, newlyFilledLots);
        if (!s.active) return (newlyFilledLots, 0);

        (uint128 shares, uint96 claimLots, uint32 generation) =
            core.quotes(s.owner, s.side, s.limitTick);
        RestingSlice storage slice = restingSlices[strategyId];

        if (shares == 0) {
            slice.shares = 0;
            slice.generation = 0;
        } else {
            if (shares != slice.shares) revert QuoteContaminated();
            slice.generation = generation;
        }

        uint96 targetVisible = _min(s.sliceLots, s.remainingLots);
        if (claimLots > targetVisible) revert QuoteContaminated();

        uint96 addLots = targetVisible - claimLots;
        if (addLots != 0) {
            uint16 ceiling = gateway.strategyReserveExposure(s.owner, s.side, addLots);
            uint128 minted =
                gateway.strategyAddLiquidity(s.owner, s.side, s.limitTick, addLots, ceiling);
            slice.shares += minted;
            (, visibleLots, slice.generation) = core.quotes(s.owner, s.side, s.limitTick);
        } else {
            visibleLots = claimLots;
        }

        emit IcebergRefreshed(
            strategyId, newlyFilledLots, visibleLots, s.remainingLots
        );
    }

    function placeTWAP(
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 totalLots,
        uint96 sliceLots,
        uint64 startTime,
        uint64 interval,
        uint64 deadline
    ) external returns (uint64 strategyId) {
        if (
            totalLots == 0 || sliceLots == 0 || interval == 0
                || deadline <= startTime
        ) revert InvalidStrategy();

        strategyId = nextStrategyId++;
        Strategy storage s = strategies[strategyId];
        s.owner = msg.sender;
        s.remainingLots = totalLots;
        s.sliceLots = sliceLots;
        s.nextExecution = startTime;
        s.interval = interval;
        s.deadline = deadline;
        s.limitTick = limitTick;
        s.side = side;
        s.kind = Kind.TWAP;
        s.active = true;
        activeStrategyCount[msg.sender] += 1;

        emit TWAPPlaced(
            strategyId,
            msg.sender,
            side,
            limitTick,
            totalLots,
            sliceLots,
            startTime,
            interval,
            deadline
        );
    }

    function executeTWAPSlice(uint64 strategyId)
        external
        returns (uint96 filledLots)
    {
        Strategy storage s = _active(strategyId, Kind.TWAP);
        if (block.timestamp < s.nextExecution) revert TooEarly();
        if (block.timestamp > s.deadline) revert StrategyExpired();

        uint96 requested = _min(s.sliceLots, s.remainingLots);
        uint16 ceiling = gateway.strategyReserveExposure(s.owner, s.side, requested);
        ceiling;
        filledLots = gateway.strategyTake(
            s.owner, s.side, s.limitTick, requested, true
        );
        if (filledLots < requested) {
            gateway.strategyReleaseExposure(
                s.owner, s.side, requested - filledLots
            );
        }

        s.remainingLots -= filledLots;
        uint64 next = s.nextExecution + s.interval;
        if (next <= block.timestamp) {
            next = uint64(block.timestamp) + s.interval;
        }
        s.nextExecution = next;

        if (s.remainingLots == 0) _complete(strategyId, s);
        emit TWAPSliceExecuted(
            strategyId, requested, filledLots, s.remainingLots, s.nextExecution
        );
    }

    function placePegged(
        IOrderBookCore.Side side,
        int16 offsetTicks,
        uint16 priceBoundTick,
        uint96 lots
    ) external returns (uint64 strategyId) {
        if (lots == 0) revert InvalidStrategy();
        uint16 tick = _peggedTick(side, offsetTicks, priceBoundTick);
        _requireCleanQuote(msg.sender, side, tick);

        strategyId = nextStrategyId++;
        Strategy storage s = strategies[strategyId];
        s.owner = msg.sender;
        s.remainingLots = lots;
        s.sliceLots = lots;
        s.limitTick = priceBoundTick;
        s.pegOffsetTicks = offsetTicks;
        s.side = side;
        s.kind = Kind.Pegged;
        s.active = true;
        activeStrategyCount[msg.sender] += 1;

        _addRestingSlice(strategyId, s, lots, tick);
        emit PeggedPlaced(
            strategyId, msg.sender, side, offsetTicks, priceBoundTick, lots, tick
        );
    }

    function syncPegged(uint64 strategyId)
        external
        returns (uint96 newlyFilledLots, uint16 nextTick)
    {
        Strategy storage s = _active(strategyId, Kind.Pegged);
        RestingSlice storage slice = restingSlices[strategyId];
        _requireExclusive(strategyId, s);

        uint16 previousTick = slice.tick;
        newlyFilledLots = gateway.strategySettle(s.owner, s.side, previousTick);
        _consumeFilled(strategyId, s, newlyFilledLots);
        if (!s.active) return (newlyFilledLots, previousTick);

        nextTick = _peggedTick(s.side, s.pegOffsetTicks, s.limitTick);
        if (nextTick == previousTick) {
            emit PeggedRepriced(
                strategyId,
                previousTick,
                nextTick,
                newlyFilledLots,
                s.remainingLots
            );
            return (newlyFilledLots, nextTick);
        }

        (uint128 shares,, uint32 generation) =
            core.quotes(s.owner, s.side, previousTick);
        if (shares != slice.shares || generation != slice.generation) {
            revert QuoteContaminated();
        }
        if (shares != 0) {
            gateway.strategyRemoveLockedShares(
                s.owner, s.side, previousTick, generation, shares
            );
        }
        delete restingSlices[strategyId];
        _requireCleanQuote(s.owner, s.side, nextTick);
        _addRestingSlice(strategyId, s, s.remainingLots, nextTick);

        emit PeggedRepriced(
            strategyId, previousTick, nextTick, newlyFilledLots, s.remainingLots
        );
    }

    function cancelStrategy(uint64 strategyId) external {
        Strategy storage s = strategies[strategyId];
        if (s.owner == address(0)) revert InvalidStrategy();
        if (s.owner != msg.sender) revert Unauthorized();
        _cancel(strategyId, s);
    }

    function liquidationCleanup(address account, uint64[] calldata strategyIds)
        external
    {
        if (msg.sender != address(gateway)) revert Unauthorized();
        for (uint256 i; i < strategyIds.length; ++i) {
            Strategy storage s = strategies[strategyIds[i]];
            if (s.owner == account && s.active) _cancel(strategyIds[i], s);
        }
    }

    function _cancel(uint64 strategyId, Strategy storage s) internal {
        if (!s.active) revert StrategyInactive();

        RestingSlice memory slice = restingSlices[strategyId];
        if (slice.shares != 0) {
            _requireExclusive(strategyId, s);
            uint96 filled = gateway.strategySettle(s.owner, s.side, slice.tick);
            if (filled > s.remainingLots) revert QuoteContaminated();
            s.remainingLots -= filled;
            (uint128 shares,, uint32 generation) =
                core.quotes(s.owner, s.side, slice.tick);
            if (shares != 0) {
                if (shares != slice.shares || generation != slice.generation) {
                    revert QuoteContaminated();
                }
                gateway.strategyRemoveLockedShares(
                    s.owner, s.side, slice.tick, generation, shares
                );
            }
            delete restingSlices[strategyId];
        }

        uint96 remaining = s.remainingLots;
        s.active = false;
        activeStrategyCount[s.owner] -= 1;
        emit StrategyCancelled(strategyId, remaining);
    }

    function _addRestingSlice(
        uint64 strategyId,
        Strategy storage s,
        uint96 lots,
        uint16 tick
    ) internal {
        uint16 ceiling = gateway.strategyReserveExposure(s.owner, s.side, lots);
        uint128 shares =
            gateway.strategyAddLiquidity(s.owner, s.side, tick, lots, ceiling);
        (uint128 totalShares,, uint32 generation) =
            core.quotes(s.owner, s.side, tick);
        if (totalShares != shares) revert QuoteContaminated();

        restingSlices[strategyId] =
            RestingSlice({shares: shares, generation: generation, tick: tick});
    }

    function _consumeFilled(
        uint64 strategyId,
        Strategy storage s,
        uint96 filledLots
    ) internal {
        if (filledLots > s.remainingLots) revert QuoteContaminated();
        s.remainingLots -= filledLots;
        if (s.remainingLots == 0) {
            delete restingSlices[strategyId];
            s.active = false;
            activeStrategyCount[s.owner] -= 1;
            emit StrategyCompleted(strategyId);
        }
    }

    function _complete(uint64 strategyId, Strategy storage s) internal {
        if (!s.active) return;
        s.active = false;
        activeStrategyCount[s.owner] -= 1;
        emit StrategyCompleted(strategyId);
    }

    function _active(uint64 strategyId, Kind kind)
        internal
        view
        returns (Strategy storage s)
    {
        s = strategies[strategyId];
        if (s.owner == address(0) || s.kind != kind) revert InvalidStrategy();
        if (!s.active) revert StrategyInactive();
    }

    function _requireCleanQuote(
        address owner,
        IOrderBookCore.Side side,
        uint16 tick
    ) internal view {
        (uint128 shares,,) = core.quotes(owner, side, tick);
        if (shares != 0) revert QuoteContaminated();
    }

    function _requireExclusive(uint64 strategyId, Strategy storage s)
        internal
        view
    {
        RestingSlice storage slice = restingSlices[strategyId];
        (uint128 shares,, uint32 generation) =
            core.quotes(s.owner, s.side, slice.tick);
        if (shares != slice.shares || generation != slice.generation) {
            revert QuoteContaminated();
        }
    }

    function _peggedTick(
        IOrderBookCore.Side side,
        int16 offsetTicks,
        uint16 priceBoundTick
    ) internal view returns (uint16 tick) {
        int256 raw = int256(uint256(core.currentMarkTick())) + int256(offsetTicks);
        if (raw < 0 || raw > int256(uint256(type(uint16).max))) {
            revert InvalidStrategy();
        }
        tick = uint16(uint256(raw));

        if (side == IOrderBookCore.Side.Bid) {
            if (tick > priceBoundTick) tick = priceBoundTick;
        } else if (tick < priceBoundTick) {
            tick = priceBoundTick;
        }
    }

    function _min(uint96 a, uint96 b) internal pure returns (uint96) {
        return a < b ? a : b;
    }
}

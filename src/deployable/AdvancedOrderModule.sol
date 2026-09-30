// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {IExtremaOracle} from "../interfaces/IExtremaOracle.sol";
import {OrderBookMath} from "./OrderBookMath.sol";

/// @title AdvancedOrderModule
/// @notice Fully-on-chain conditional, triggered-limit, OCO/OTO, bracket and trailing logic.
/// @dev The module owns only advanced-order state. Matching/risk/custody remain in OrderBookCore.
contract AdvancedOrderModule {
    uint8 internal constant FLAG_ACTIVE = 1 << 0;
    uint8 internal constant FLAG_TRIGGER_ABOVE = 1 << 1;
    uint8 internal constant FLAG_REDUCE_ONLY = 1 << 2;
    uint8 internal constant FLAG_TRIGGERED_LIMIT = 1 << 3;
    uint8 internal constant FLAG_DORMANT = 1 << 4;
    struct ConditionalOrder {
        address owner;
        uint96 lots;
        uint64 sibling;
        uint16 triggerTick;
        uint16 limitTick;
        uint16 riskCeilingTick;
        IOrderBookCore.Side side;
        IOrderBookCore.FillPolicy policy;
        uint8 flags;
    }

    struct TrailingOrder {
        address owner;
        uint96 lots;
        uint64 observationId;
        uint16 trailTicks;
        uint16 limitTick;
        uint16 riskCeilingTick;
        IOrderBookCore.Side side;
        IOrderBookCore.FillPolicy policy;
        uint8 flags;
    }

    struct RestingLink {
        uint128 shares;
        uint96 remainingClaimLots;
        uint96 cumulativeFilledLots;
        uint32 generation;
        bool active;
    }

    struct ManagedQuote {
        uint128 shares;
        uint32 generation;
    }

    struct QuoteUpdate {
        IOrderBookCore.Side side;
        uint16 tick;
        uint96 lots;
    }

    error Unauthorized();
    error ZeroAmount();
    error OrderNotFound();
    error OrderInactive();
    error TriggerNotSatisfied();
    error InvalidOCO();
    error InvalidOTO();
    error InvalidRiskCeiling();
    error ReduceOnlyViolation();
    error RestingOrderNotFound();
    error InvalidLiquidationConfig();
    error NotLiquidatable();
    error UnsettledAdvancedOrders();
    error MinimumFillNotMet();

    IOrderBookCore public immutable core;
    IExtremaOracle public immutable extremaOracle;
    address internal immutable owner;

    uint16 internal maintenanceMarginBps;
    mapping(address => uint32) public activeAdvancedCount;

    uint64 internal nextConditionalOrderId = 1;
    uint64 internal nextTrailingOrderId = 1;

    mapping(uint64 => ConditionalOrder) public conditionalOrders;
    mapping(uint64 => TrailingOrder) public trailingOrders;
    mapping(uint64 => RestingLink) internal restingLinks;

    mapping(uint64 => uint64) internal otoChildOne;
    mapping(uint64 => uint64) internal otoChildTwo;
    mapping(uint64 => uint64) internal otoParent;
    mapping(uint64 => uint96) internal otoChildMaxLots;
    mapping(address => mapping(IOrderBookCore.Side => mapping(uint16 => ManagedQuote)))
        internal managedQuotes;

    event ConditionalOrderPlaced(
        uint64 indexed orderId,
        address indexed owner,
        IOrderBookCore.Side side,
        uint16 triggerTick,
        uint16 limitTick,
        uint96 lots,
        bool triggerAboveOrEqual,
        bool reduceOnly,
        bool triggeredLimit
    );
    event ConditionalOrderCancelled(uint64 indexed orderId);
    event ConditionalOrderExecuted(uint64 indexed orderId, uint96 filledLots);
    event OCOLinked(uint64 indexed firstOrderId, uint64 indexed secondOrderId);
    event OTOLinked(uint64 indexed parentOrderId, uint64 indexed childOrderId);
    event OTOActivated(uint64 indexed parentOrderId, uint64 indexed childOrderId, uint96 lots);
    event OTOResized(uint64 indexed parentOrderId, uint64 indexed childOrderId, uint96 lots);
    event RestingOrderLinked(
        uint64 indexed parentOrderId,
        uint128 shares,
        uint96 remainingLots,
        uint96 cumulativeFilledLots
    );
    event RestingOrderSynced(
        uint64 indexed parentOrderId,
        uint96 newlyFilledLots,
        uint96 cumulativeFilledLots,
        uint96 remainingLots
    );
    event RestingOrderCancelled(uint64 indexed parentOrderId, uint96 removedLots);

    event TrailingOrderPlaced(
        uint64 indexed orderId,
        address indexed owner,
        IOrderBookCore.Side side,
        uint64 observationId,
        uint16 trailTicks,
        uint16 limitTick,
        uint96 lots,
        bool reduceOnly
    );
    event TrailingOrderCancelled(uint64 indexed orderId);
    event TrailingOrderExecuted(
        uint64 indexed orderId,
        uint96 filledLots,
        uint16 highTick,
        uint16 lowTick
    );
    event LiquidationConfigured(uint16 maintenanceMarginBps);
    event Liquidated(
        address indexed liquidator,
        address indexed account,
        uint96 closedLots,
        int256 equityBefore
    );

    constructor(address core_, address extremaOracle_) {
        if (core_ == address(0) || extremaOracle_ == address(0)) revert Unauthorized();

        IOrderBookCore coreRef = IOrderBookCore(core_);
        if (address(coreRef.markOracle()) != extremaOracle_) revert InvalidRiskCeiling();

        core = coreRef;
        extremaOracle = IExtremaOracle(extremaOracle_);
        owner = msg.sender;
    }

    function configureLiquidation(uint16 maintenanceBps) external {
        if (msg.sender != owner) revert Unauthorized();
        if (maintenanceBps == 0 || maintenanceBps > 10_000) {
            revert InvalidLiquidationConfig();
        }

        maintenanceMarginBps = maintenanceBps;
        emit LiquidationConfigured(maintenanceBps);
    }

    function takeReduceOnly(
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 lots,
        IOrderBookCore.FillPolicy policy
    ) external returns (uint96 filledLots) {
        filledLots = core.moduleTake(
            msg.sender,
            side,
            limitTick,
            lots,
            policy,
            true,
            false
        );
    }

    function takeMinFill(
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 lots,
        uint96 minFillLots,
        bool reduceOnly
    ) external returns (uint96 filledLots) {
        if (minFillLots == 0 || minFillLots > lots) revert MinimumFillNotMet();

        filledLots = core.moduleTake(
            msg.sender,
            side,
            limitTick,
            lots,
            IOrderBookCore.FillPolicy.IOC,
            reduceOnly,
            false
        );

        // Reverting here atomically rolls back all core fills when the threshold is missed.
        if (filledLots < minFillLots) revert MinimumFillNotMet();
    }

    /// @notice Atomically replace/cancel module-managed maker quotes.
    /// @dev lots == 0 cancels the managed slice at that maker/side/tick.
    function batchReplaceQuotes(QuoteUpdate[] calldata updates) external {
        uint256 length = updates.length;
        if (length == 0) revert ZeroAmount();

        uint96 bidLots;
        uint96 askLots;

        // Phase 1: remove old managed slices and determine the new side exposure.
        for (uint256 i; i < length; ) {
            QuoteUpdate calldata update = updates[i];
            _clearManagedQuote(msg.sender, update.side, update.tick);

            if (update.side == IOrderBookCore.Side.Bid) {
                bidLots += update.lots;
            } else {
                askLots += update.lots;
            }

            unchecked {
                ++i;
            }
        }

        // Phase 2: reserve margin/risk only once per side.
        uint16 bidCeiling;
        uint16 askCeiling;
        if (bidLots != 0) {
            bidCeiling =
                core.moduleReserveExposure(msg.sender, IOrderBookCore.Side.Bid, bidLots);
        }
        if (askLots != 0) {
            askCeiling =
                core.moduleReserveExposure(msg.sender, IOrderBookCore.Side.Ask, askLots);
        }

        // Phase 3: rebuild target slices using the shared side reservation.
        for (uint256 i; i < length; ) {
            QuoteUpdate calldata update = updates[i];

            if (update.lots != 0) {
                uint16 ceiling =
                    update.side == IOrderBookCore.Side.Bid ? bidCeiling : askCeiling;
                uint128 shares = core.moduleAddLiquidity(
                    msg.sender,
                    update.side,
                    update.tick,
                    update.lots,
                    ceiling
                );
                (,, uint32 generation) = core.pools(update.side, update.tick);

                ManagedQuote storage managed =
                    managedQuotes[msg.sender][update.side][update.tick];
                if (managed.shares == 0) {
                    managed.generation = generation;
                }
                managed.shares += shares;
            }

            unchecked {
                ++i;
            }
        }
    }

    function _clearManagedQuote(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick
    ) internal {
        ManagedQuote memory managed = managedQuotes[maker][side][tick];
        if (managed.shares == 0) return;

        (,, uint32 currentGeneration) = core.pools(side, tick);

        if (currentGeneration == managed.generation) {
            core.moduleRemoveLockedShares(
                maker,
                side,
                tick,
                managed.generation,
                managed.shares
            );
        } else {
            core.moduleUnlockShares(
                maker,
                side,
                tick,
                managed.generation,
                managed.shares
            );
        }

        delete managedQuotes[maker][side][tick];
    }

    function placeConditionalOrder(
        IOrderBookCore.Side side,
        bool triggerAboveOrEqual,
        uint16 triggerTick,
        uint16 limitTick,
        uint96 lots,
        IOrderBookCore.FillPolicy policy,
        bool reduceOnly
    ) external returns (uint64 orderId) {
        orderId = _placeConditional(
            msg.sender,
            side,
            triggerAboveOrEqual,
            triggerTick,
            limitTick,
            lots,
            policy,
            reduceOnly,
            false
        );
    }

    function placeTriggeredLimitOrder(
        IOrderBookCore.Side side,
        bool triggerAboveOrEqual,
        uint16 triggerTick,
        uint16 limitTick,
        uint96 lots
    ) external returns (uint64 orderId) {
        orderId = _placeConditional(
            msg.sender,
            side,
            triggerAboveOrEqual,
            triggerTick,
            limitTick,
            lots,
            IOrderBookCore.FillPolicy.IOC,
            false,
            true
        );
    }

    function _placeConditional(
        address account,
        IOrderBookCore.Side side,
        bool triggerAboveOrEqual,
        uint16 triggerTick,
        uint16 limitTick,
        uint96 lots,
        IOrderBookCore.FillPolicy policy,
        bool reduceOnly,
        bool triggeredLimit
    ) internal returns (uint64 orderId) {
        if (lots == 0) revert ZeroAmount();

        uint16 riskCeiling;
        if (!reduceOnly) {
            riskCeiling = core.moduleReserveExposure(account, side, lots);
        }

        uint8 flags = FLAG_ACTIVE;
        if (triggerAboveOrEqual) flags |= FLAG_TRIGGER_ABOVE;
        if (reduceOnly) flags |= FLAG_REDUCE_ONLY;
        if (triggeredLimit) flags |= FLAG_TRIGGERED_LIMIT;

        orderId = nextConditionalOrderId++;
        ConditionalOrder memory order = ConditionalOrder({
            owner: account,
            lots: lots,
            sibling: 0,
            triggerTick: triggerTick,
            limitTick: limitTick,
            riskCeilingTick: riskCeiling,
            side: side,
            policy: policy,
            flags: flags
        });

        conditionalOrders[orderId] = order;
        activeAdvancedCount[account] += 1;
        _emitConditionalPlaced(orderId, order);
    }

    function _emitConditionalPlaced(uint64 orderId, ConditionalOrder memory order)
        internal
    {
        emit ConditionalOrderPlaced(
            orderId,
            order.owner,
            order.side,
            order.triggerTick,
            order.limitTick,
            order.lots,
            (order.flags & FLAG_TRIGGER_ABOVE) != 0,
            (order.flags & FLAG_REDUCE_ONLY) != 0,
            (order.flags & FLAG_TRIGGERED_LIMIT) != 0
        );
    }

    function cancelConditionalOrder(uint64 orderId) external {
        ConditionalOrder storage order = conditionalOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert Unauthorized();

        if (!_active(order) && restingLinks[orderId].active) {
            _cancelRestingOrder(orderId);
            return;
        }

        _cancelConditional(orderId, true);
    }

    function linkOCO(uint64 firstOrderId, uint64 secondOrderId) external {
        if (firstOrderId == secondOrderId) revert InvalidOCO();

        ConditionalOrder storage first = conditionalOrders[firstOrderId];
        ConditionalOrder storage second = conditionalOrders[secondOrderId];

        if (first.owner == address(0) || second.owner == address(0)) revert OrderNotFound();
        if (first.owner != msg.sender || second.owner != msg.sender) revert Unauthorized();
        if (!_active(first) || !_active(second)) revert OrderInactive();
        if (first.sibling != 0 || second.sibling != 0) revert InvalidOCO();

        first.sibling = secondOrderId;
        second.sibling = firstOrderId;

        emit OCOLinked(firstOrderId, secondOrderId);
    }

    function linkOTO(uint64 parentOrderId, uint64 childOrderId) external {
        if (parentOrderId == childOrderId) revert InvalidOTO();

        ConditionalOrder storage parent = conditionalOrders[parentOrderId];
        ConditionalOrder storage child = conditionalOrders[childOrderId];

        if (parent.owner == address(0) || child.owner == address(0)) revert OrderNotFound();
        if (parent.owner != msg.sender || child.owner != msg.sender) revert Unauthorized();
        if (!_active(parent) || !_active(child)) revert OrderInactive();
        if ((child.flags & FLAG_REDUCE_ONLY) == 0 || otoParent[childOrderId] != 0) revert InvalidOTO();

        if (otoChildOne[parentOrderId] == 0) {
            otoChildOne[parentOrderId] = childOrderId;
        } else if (otoChildTwo[parentOrderId] == 0) {
            otoChildTwo[parentOrderId] = childOrderId;
        } else {
            revert InvalidOTO();
        }

        otoParent[childOrderId] = parentOrderId;
        otoChildMaxLots[childOrderId] = child.lots;

        child.flags = (child.flags & ~FLAG_ACTIVE) | FLAG_DORMANT;

        emit OTOLinked(parentOrderId, childOrderId);
    }

    function executeConditionalOrder(uint64 orderId) external returns (uint96 filledLots) {
        ConditionalOrder storage stored = conditionalOrders[orderId];
        if (stored.owner == address(0)) revert OrderNotFound();
        if (!_active(stored)) revert OrderInactive();

        ConditionalOrder memory order = stored;
        uint16 mark = core.currentMarkTick();

        bool triggerAbove = (order.flags & FLAG_TRIGGER_ABOVE) != 0;
        if (triggerAbove ? mark < order.triggerTick : mark > order.triggerTick) {
            revert TriggerNotSatisfied();
        }

        uint64 parentOfExit = otoParent[orderId];
        if (parentOfExit != 0 && restingLinks[parentOfExit].active) {
            _syncRestingOrder(parentOfExit);
            _cancelRestingOrder(parentOfExit);
            order = stored;
        }

        bool reduceOnly = (order.flags & FLAG_REDUCE_ONLY) != 0;
        if (reduceOnly && core.activeQuoteCount(order.owner) != 0) {
            revert ReduceOnlyViolation();
        }
        if (!reduceOnly && order.riskCeilingTick != 0 && mark > order.riskCeilingTick) {
            revert InvalidRiskCeiling();
        }

        bool triggeredLimit = (order.flags & FLAG_TRIGGERED_LIMIT) != 0;
        stored.flags &= ~FLAG_ACTIVE;

        if (triggeredLimit) {
            filledLots = _executeTriggeredLimit(orderId, order);
        } else {
            filledLots = core.moduleTake(
                order.owner,
                order.side,
                order.limitTick,
                order.lots,
                order.policy,
                reduceOnly,
                !reduceOnly
            );

            if (!reduceOnly) {
                uint96 unfilled = order.lots - filledLots;
                if (unfilled != 0) {
                    core.moduleReleaseExposure(order.owner, order.side, unfilled);
                }
            }

            if (filledLots != 0) {
                _resizeOTOChildren(orderId, order.owner, filledLots);
            } else {
                _cancelOTOChildren(orderId);
            }
        }

        if (!restingLinks[orderId].active) {
            activeAdvancedCount[order.owner] -= 1;
        }

        uint64 sibling = order.sibling;
        if (sibling != 0) _cancelConditional(sibling, true);

        emit ConditionalOrderExecuted(orderId, filledLots);
    }

    function _executeTriggeredLimit(uint64 orderId, ConditionalOrder memory order)
        internal
        returns (uint96 filledLots)
    {
        filledLots = core.moduleTake(
            order.owner,
            order.side,
            order.limitTick,
            order.lots,
            IOrderBookCore.FillPolicy.IOC,
            false,
            true
        );

        uint96 restingLots = order.lots - filledLots;

        if (restingLots != 0) {
            uint128 shares = core.moduleAddLiquidity(
                order.owner,
                order.side,
                order.limitTick,
                restingLots,
                order.riskCeilingTick
            );

            (, , uint32 generation) =
                core.quotes(order.owner, order.side, order.limitTick);

            restingLinks[orderId] = RestingLink({
                shares: shares,
                remainingClaimLots: restingLots,
                cumulativeFilledLots: filledLots,
                generation: generation,
                active: true
            });

            emit RestingOrderLinked(orderId, shares, restingLots, filledLots);
        }

        if (filledLots != 0) {
            _resizeOTOChildren(orderId, order.owner, filledLots);
        } else if (restingLots == 0) {
            _cancelOTOChildren(orderId);
        }
    }

    function syncRestingOrder(uint64 parentOrderId)
        external
        returns (uint96 newlyFilledLots, uint96 cumulativeFilledLots)
    {
        ConditionalOrder storage parent = conditionalOrders[parentOrderId];
        if (parent.owner == address(0) || !restingLinks[parentOrderId].active) {
            revert RestingOrderNotFound();
        }

        core.moduleSettle(parent.owner, parent.side, parent.limitTick);
        (newlyFilledLots, cumulativeFilledLots) = _syncRestingOrder(parentOrderId);
    }

    function cancelRestingOrder(uint64 parentOrderId) external returns (uint96 removedLots) {
        ConditionalOrder storage parent = conditionalOrders[parentOrderId];
        if (parent.owner == address(0)) revert OrderNotFound();
        if (parent.owner != msg.sender) revert Unauthorized();

        removedLots = _cancelRestingOrder(parentOrderId);
    }

    function _syncRestingOrder(uint64 parentOrderId)
        internal
        returns (uint96 newlyFilledLots, uint96 cumulativeFilledLots)
    {
        RestingLink storage link = restingLinks[parentOrderId];
        if (!link.active) return (0, 0);

        ConditionalOrder storage parent = conditionalOrders[parentOrderId];

        (uint128 totalShares, uint96 remainingLots, uint32 generation) =
            core.pools(parent.side, parent.limitTick);

        uint96 currentClaim;
        if (generation == link.generation && totalShares != 0 && remainingLots != 0) {
            currentClaim = uint96(
                uint256(link.shares) * uint256(remainingLots) / uint256(totalShares)
            );
        }

        if (currentClaim < link.remainingClaimLots) {
            newlyFilledLots = link.remainingClaimLots - currentClaim;
            link.remainingClaimLots = currentClaim;
            link.cumulativeFilledLots += newlyFilledLots;
            _resizeOTOChildren(parentOrderId, parent.owner, link.cumulativeFilledLots);
        }

        cumulativeFilledLots = link.cumulativeFilledLots;

        emit RestingOrderSynced(
            parentOrderId,
            newlyFilledLots,
            cumulativeFilledLots,
            currentClaim
        );

        if (currentClaim == 0) {
            core.moduleUnlockShares(
                parent.owner,
                parent.side,
                parent.limitTick,
                link.generation,
                link.shares
            );
            delete restingLinks[parentOrderId];
            activeAdvancedCount[parent.owner] -= 1;
        }
    }

    function _cancelRestingOrder(uint64 parentOrderId)
        internal
        returns (uint96 removedLots)
    {
        RestingLink storage link = restingLinks[parentOrderId];
        if (!link.active) return 0;

        ConditionalOrder storage parent = conditionalOrders[parentOrderId];

        core.moduleSettle(parent.owner, parent.side, parent.limitTick);
        _syncRestingOrder(parentOrderId);

        RestingLink storage live = restingLinks[parentOrderId];
        if (!live.active) return 0;

        removedLots = core.moduleRemoveLockedShares(
            parent.owner,
            parent.side,
            parent.limitTick,
            live.generation,
            live.shares
        );

        delete restingLinks[parentOrderId];
        activeAdvancedCount[parent.owner] -= 1;

        emit RestingOrderCancelled(parentOrderId, removedLots);
    }

    function placeTrailingOrder(
        IOrderBookCore.Side side,
        uint16 trailTicks,
        uint16 limitTick,
        uint96 lots,
        IOrderBookCore.FillPolicy policy,
        bool reduceOnly
    ) external returns (uint64 orderId) {
        if (lots == 0 || trailTicks == 0) revert ZeroAmount();

        uint16 riskCeiling;
        if (!reduceOnly) {
            riskCeiling = core.moduleReserveExposure(msg.sender, side, lots);
        }

        orderId = nextTrailingOrderId++;
        trailingOrders[orderId] = TrailingOrder({
            owner: msg.sender,
            lots: lots,
            observationId: extremaOracle.currentObservationId(),
            trailTicks: trailTicks,
            limitTick: limitTick,
            riskCeilingTick: riskCeiling,
            side: side,
            policy: policy,
            flags: reduceOnly ? (FLAG_ACTIVE | FLAG_REDUCE_ONLY) : FLAG_ACTIVE
        });

        activeAdvancedCount[msg.sender] += 1;

        emit TrailingOrderPlaced(
            orderId,
            msg.sender,
            side,
            trailingOrders[orderId].observationId,
            trailTicks,
            limitTick,
            lots,
            reduceOnly
        );
    }

    function cancelTrailingOrder(uint64 orderId) external {
        TrailingOrder storage order = trailingOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert Unauthorized();

        _cancelTrailing(orderId, true);
    }

    function executeTrailingOrder(uint64 orderId) external returns (uint96 filledLots) {
        TrailingOrder storage stored = trailingOrders[orderId];
        if (stored.owner == address(0)) revert OrderNotFound();
        if ((stored.flags & FLAG_ACTIVE) == 0) revert OrderInactive();

        TrailingOrder memory order = stored;
        uint16 current = core.currentMarkTick();

        (uint16 highTick, uint16 lowTick) =
            extremaOracle.highLowSince(order.observationId);

        bool triggered;
        if (order.side == IOrderBookCore.Side.Ask) {
            triggered = uint256(current) + uint256(order.trailTicks) <= uint256(highTick);
        } else {
            triggered =
                uint256(current) >= uint256(lowTick) + uint256(order.trailTicks);
        }

        if (!triggered) revert TriggerNotSatisfied();

        bool reduceOnly = (order.flags & FLAG_REDUCE_ONLY) != 0;
        if (reduceOnly && core.activeQuoteCount(order.owner) != 0) {
            revert ReduceOnlyViolation();
        }
        if (!reduceOnly && order.riskCeilingTick != 0 && current > order.riskCeilingTick) {
            revert InvalidRiskCeiling();
        }

        stored.flags &= ~FLAG_ACTIVE;
        activeAdvancedCount[order.owner] -= 1;

        filledLots = core.moduleTake(
            order.owner,
            order.side,
            order.limitTick,
            order.lots,
            order.policy,
            reduceOnly,
            !reduceOnly
        );

        if (!reduceOnly) {
            uint96 unfilled = order.lots - filledLots;
            if (unfilled != 0) {
                core.moduleReleaseExposure(order.owner, order.side, unfilled);
            }
        }

        emit TrailingOrderExecuted(orderId, filledLots, highTick, lowTick);
    }

    function _settledPosition(address account) internal view returns (int80 position) {
        (position,,) = core.accountRisk(account);
    }

    function maintenanceRequirement(address account) public view returns (uint256) {
        uint16 maintenanceBps = maintenanceMarginBps;
        if (maintenanceBps == 0) return 0;

        int80 position = _settledPosition(account);
        uint256 absPosition = uint256(OrderBookMath.absPosition(position));

        return absPosition * uint256(core.currentMarkTick()) * uint256(maintenanceBps)
            / 10_000;
    }

    function isLiquidatable(address account) external view returns (bool) {
        if (maintenanceMarginBps == 0) return false;
        if (core.activeQuoteCount(account) != 0 || activeAdvancedCount[account] != 0) {
            return false;
        }
        if (_settledPosition(account) == 0) return false;

        return core.accountEquity(account) < int256(maintenanceRequirement(account));
    }

    function liquidate(
        address account,
        IOrderBookCore.Side[] calldata makerSides,
        uint16[] calldata makerTicks,
        uint64[] calldata conditionalIds,
        uint64[] calldata trailingIds
    ) external returns (uint96 closedLots) {
        if (maintenanceMarginBps == 0) revert InvalidLiquidationConfig();
        if (makerSides.length != makerTicks.length) revert UnsettledAdvancedOrders();

        for (uint256 i; i < conditionalIds.length; ++i) {
            uint64 id = conditionalIds[i];
            ConditionalOrder storage order = conditionalOrders[id];
            if (order.owner != account) continue;

            if (restingLinks[id].active) {
                _cancelRestingOrder(id);
            } else if (_active(order) || _dormant(order)) {
                _cancelConditional(id, true);
            }
        }

        for (uint256 i; i < trailingIds.length; ++i) {
            uint64 id = trailingIds[i];
            TrailingOrder storage order = trailingOrders[id];
            if (order.owner == account && (order.flags & FLAG_ACTIVE) != 0) {
                _cancelTrailing(id, true);
            }
        }

        for (uint256 i; i < makerTicks.length; ++i) {
            core.moduleForceCancelQuote(account, makerSides[i], makerTicks[i]);
        }

        if (core.activeQuoteCount(account) != 0 || activeAdvancedCount[account] != 0) {
            revert UnsettledAdvancedOrders();
        }

        int256 equityBefore = core.accountEquity(account);
        if (equityBefore >= int256(maintenanceRequirement(account))) {
            revert NotLiquidatable();
        }

        int80 position = _settledPosition(account);
        if (position > 0) {
            closedLots = core.moduleTake(
                account,
                IOrderBookCore.Side.Ask,
                0,
                uint96(uint80(position)),
                IOrderBookCore.FillPolicy.IOC,
                true,
                false
            );
        } else if (position < 0) {
            closedLots = core.moduleTake(
                account,
                IOrderBookCore.Side.Bid,
                type(uint16).max,
                uint96(uint80(-position)),
                IOrderBookCore.FillPolicy.IOC,
                true,
                false
            );
        } else {
            revert NotLiquidatable();
        }

        emit Liquidated(msg.sender, account, closedLots, equityBefore);
    }

    function _resizeOTOChildren(uint64 parentOrderId, address owner_, uint96 filledLots)
        internal
    {
        uint64 first = otoChildOne[parentOrderId];
        uint64 second = otoChildTwo[parentOrderId];

        if (first != 0) _resizeOTOChild(parentOrderId, first, owner_, filledLots);
        if (second != 0) _resizeOTOChild(parentOrderId, second, owner_, filledLots);
    }

    function _resizeOTOChild(
        uint64 parentOrderId,
        uint64 childOrderId,
        address owner_,
        uint96 filledLots
    ) internal {
        ConditionalOrder storage child = conditionalOrders[childOrderId];
        if (child.owner != owner_ || (child.flags & FLAG_REDUCE_ONLY) == 0) revert InvalidOTO();

        uint96 maxLots = otoChildMaxLots[childOrderId];
        uint96 targetLots = filledLots < maxLots ? filledLots : maxLots;
        if (targetLots == 0) return;

        bool dormant = _dormant(child);
        bool active = _active(child);

        if (dormant) {
            child.lots = targetLots;
            child.flags = (child.flags | FLAG_ACTIVE) & ~FLAG_DORMANT;
            emit OTOActivated(parentOrderId, childOrderId, targetLots);
        } else if (active && targetLots > child.lots) {
            child.lots = targetLots;
            emit OTOResized(parentOrderId, childOrderId, targetLots);
        }
    }

    function _cancelOTOChildren(uint64 parentOrderId) internal {
        uint64 first = otoChildOne[parentOrderId];
        uint64 second = otoChildTwo[parentOrderId];

        if (first != 0) {
            _cancelConditional(first, true);
            delete otoParent[first];
            delete otoChildMaxLots[first];
        }

        if (second != 0) {
            _cancelConditional(second, true);
            delete otoParent[second];
            delete otoChildMaxLots[second];
        }

        delete otoChildOne[parentOrderId];
        delete otoChildTwo[parentOrderId];
    }

    function _cancelConditional(uint64 orderId, bool releaseRisk) internal {
        ConditionalOrder storage order = conditionalOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();

        bool active = _active(order);
        bool dormant = _dormant(order);
        if (!active && !dormant) return;

        order.flags &= ~(FLAG_ACTIVE | FLAG_DORMANT);
        activeAdvancedCount[order.owner] -= 1;

        bool reduceOnly = (order.flags & FLAG_REDUCE_ONLY) != 0;
        if (releaseRisk && !reduceOnly) {
            core.moduleReleaseExposure(order.owner, order.side, order.lots);
        }

        uint64 sibling = order.sibling;
        if (sibling != 0) {
            ConditionalOrder storage other = conditionalOrders[sibling];
            if (other.owner != address(0) && other.sibling == orderId) {
                other.sibling = 0;
            }
            order.sibling = 0;
        }

        if (otoChildOne[orderId] != 0 || otoChildTwo[orderId] != 0) {
            _cancelOTOChildren(orderId);
        }

        emit ConditionalOrderCancelled(orderId);
    }

    function _cancelTrailing(uint64 orderId, bool releaseRisk) internal {
        TrailingOrder storage order = trailingOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if ((order.flags & FLAG_ACTIVE) == 0) return;

        order.flags &= ~FLAG_ACTIVE;
        activeAdvancedCount[order.owner] -= 1;

        bool reduceOnly = (order.flags & FLAG_REDUCE_ONLY) != 0;
        if (releaseRisk && !reduceOnly) {
            core.moduleReleaseExposure(order.owner, order.side, order.lots);
        }

        emit TrailingOrderCancelled(orderId);
    }

    function _active(ConditionalOrder storage order) internal view returns (bool) {
        return (order.flags & FLAG_ACTIVE) != 0;
    }

    function _dormant(ConditionalOrder storage order) internal view returns (bool) {
        return (order.flags & FLAG_DORMANT) != 0;
    }
}


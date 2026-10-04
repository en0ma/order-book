// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {IExtremaOracle} from "../interfaces/IExtremaOracle.sol";

/// @title AdvancedOrderModule
/// @notice Fully-on-chain conditional, triggered-limit, OCO/OTO, bracket and trailing logic.
/// @dev The module owns only advanced-order state. Matching/risk/custody remain in OrderBookCore.
interface IPortfolioAdmissionGateway {
    function gatewayReserveExposure(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) external returns (uint16 riskCeilingTick);

    function gatewayReleaseExposure(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) external;

    function gatewayLiquidationReleaseExposure(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) external;

    function gatewayTake(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 lots,
        IOrderBookCore.FillPolicy policy,
        bool reduceOnly,
        bool preReserved
    ) external returns (uint96 filledLots);

    function gatewayAddLiquidity(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots,
        uint16 reservedRiskCeiling
    ) external returns (uint128 mintedShares);
}

interface IMarketMakerLiquidationCleanup {
    function liquidationForgetManagedQuote(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick
    ) external;
}

contract AdvancedOrderModule {
    uint8 internal constant FLAG_ACTIVE = 1 << 0;
    uint8 internal constant FLAG_TRIGGER_ABOVE = 1 << 1;
    uint8 internal constant FLAG_REDUCE_ONLY = 1 << 2;
    uint8 internal constant FLAG_TRIGGERED_LIMIT = 1 << 3;
    uint8 internal constant FLAG_DORMANT = 1 << 4;
    uint8 internal constant FLAG_POST_ONLY = 1 << 5;
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
    error UnsettledAdvancedOrders();
    error MinimumFillNotMet();
    error InvalidExpiry();
    error OrderExpired();
    error MarketMakerModuleAlreadyConfigured();
    error LiquidationModuleAlreadyConfigured();
    error PortfolioControllerAlreadyConfigured();

    IOrderBookCore public immutable core;
    IExtremaOracle internal immutable extremaOracle;
    address public owner;
    address public marketMakerModule;
    address public liquidationModule;
    IPortfolioAdmissionGateway public portfolioController;
    uint8 public portfolioMarketIndex;

    mapping(address => uint32) internal activeAdvancedCount;
    mapping(uint64 => uint64) public conditionalExpiry;
    mapping(uint64 => uint64) public trailingExpiry;

    uint64 internal nextConditionalOrderId = 1;
    uint64 internal nextTrailingOrderId = 1;

    mapping(uint64 => ConditionalOrder) public conditionalOrders;
    mapping(uint64 => TrailingOrder) internal trailingOrders;
    mapping(uint64 => RestingLink) internal restingLinks;

    mapping(uint64 => uint64) internal otoChildOne;
    mapping(uint64 => uint64) internal otoChildTwo;
    mapping(uint64 => uint64) internal otoParent;
    mapping(uint64 => uint96) internal otoChildMaxLots;

    event OwnershipTransferred(address indexed previousOwner, address indexed nextOwner);
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
    event ConditionalExpirySet(uint64 indexed orderId, uint64 expiry);
    event ConditionalOrderExpired(uint64 indexed orderId);
    event TriggeredPostOnlyOrderPlaced(uint64 indexed orderId);

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
    event TrailingExpirySet(uint64 indexed orderId, uint64 expiry);
    event TrailingOrderExpired(uint64 indexed orderId);
    event TrailingOrderExecuted(
        uint64 indexed orderId,
        uint96 filledLots,
        uint16 highTick,
        uint16 lowTick
    );

    constructor(address core_, address extremaOracle_) {
        if (core_ == address(0) || extremaOracle_ == address(0)) revert Unauthorized();

        IOrderBookCore coreRef = IOrderBookCore(core_);
        if (address(coreRef.markOracle()) != extremaOracle_) revert InvalidRiskCeiling();

        core = coreRef;
        extremaOracle = IExtremaOracle(extremaOracle_);
        owner = msg.sender;
    }

    function transferOwnership(address nextOwner) external {
        if (msg.sender != owner || nextOwner == address(0)) revert Unauthorized();
        address previousOwner = owner;
        owner = nextOwner;
        emit OwnershipTransferred(previousOwner, nextOwner);
    }

    modifier onlyMarketMakerModule() {
        if (msg.sender != marketMakerModule || msg.sender == address(0)) revert Unauthorized();
        _;
    }

    function configurePortfolioController(address controller_, uint8 marketIndex_)
        external
    {
        if (msg.sender != owner) revert Unauthorized();
        if (controller_ == address(0)) revert Unauthorized();
        if (address(portfolioController) != address(0)) {
            revert PortfolioControllerAlreadyConfigured();
        }

        portfolioController = IPortfolioAdmissionGateway(controller_);
        portfolioMarketIndex = marketIndex_;
    }

    function configureMarketMakerModule(address module_) external {
        if (msg.sender != owner) revert Unauthorized();
        if (module_ == address(0)) revert Unauthorized();
        if (marketMakerModule != address(0)) revert MarketMakerModuleAlreadyConfigured();
        marketMakerModule = module_;
    }

    function marketMakerReserveExposure(
        address maker,
        IOrderBookCore.Side side,
        uint96 lots
    ) external onlyMarketMakerModule returns (uint16 riskCeilingTick) {
        riskCeilingTick = _reserveExposure(maker, side, lots);
    }

    function marketMakerAddLiquidity(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots,
        uint16 riskCeilingTick
    ) external onlyMarketMakerModule returns (uint128 shares) {
        shares = _addLiquidity(maker, side, tick, lots, riskCeilingTick);
    }

    function marketMakerRemoveLockedShares(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick,
        uint32 generation,
        uint128 shares
    ) external onlyMarketMakerModule returns (uint96 removedLots) {
        removedLots =
            core.moduleRemoveLockedShares(maker, side, tick, generation, shares);
    }

    function marketMakerUnlockShares(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick,
        uint32 generation,
        uint128 shares
    ) external onlyMarketMakerModule {
        core.moduleUnlockShares(maker, side, tick, generation, shares);
    }

    modifier onlyLiquidationModule() {
        if (msg.sender != liquidationModule || msg.sender == address(0)) revert Unauthorized();
        _;
    }

    function configureLiquidationModule(address module_) external {
        if (msg.sender != owner) revert Unauthorized();
        if (module_ == address(0)) revert Unauthorized();
        if (liquidationModule != address(0)) revert LiquidationModuleAlreadyConfigured();
        liquidationModule = module_;
    }

    function activeAdvancedOrders(address account) external view returns (uint32) {
        return activeAdvancedCount[account];
    }

    function trailingOrderState(uint64 orderId)
        external
        view
        returns (TrailingOrder memory order)
    {
        return trailingOrders[orderId];
    }

    function restingOrderState(uint64 orderId)
        external
        view
        returns (RestingLink memory link)
    {
        return restingLinks[orderId];
    }

    function otoState(uint64 orderId)
        external
        view
        returns (
            uint64 parentOrderId,
            uint64 firstChildOrderId,
            uint64 secondChildOrderId,
            uint96 childMaxLots
        )
    {
        parentOrderId = otoParent[orderId];
        firstChildOrderId = otoChildOne[orderId];
        secondChildOrderId = otoChildTwo[orderId];
        childMaxLots = otoChildMaxLots[orderId];
    }

    function liquidationCleanupAdvanced(
        address account,
        uint64[] calldata conditionalIds,
        uint64[] calldata trailingIds
    ) external onlyLiquidationModule {
        for (uint256 i; i < conditionalIds.length; ++i) {
            uint64 id = conditionalIds[i];
            ConditionalOrder storage order = conditionalOrders[id];
            if (order.owner != account) continue;

            if (restingLinks[id].active) {
                _cancelRestingOrder(id, true);
            } else if (_active(order) || _dormant(order)) {
                _cancelConditional(id, true, true);
            }
        }

        for (uint256 i; i < trailingIds.length; ++i) {
            uint64 id = trailingIds[i];
            TrailingOrder storage order = trailingOrders[id];
            if (order.owner == account && (order.flags & FLAG_ACTIVE) != 0) {
                _cancelTrailing(id, true, true);
            }
        }

        if (activeAdvancedCount[account] != 0) revert UnsettledAdvancedOrders();
    }

    function liquidationForceCancelQuote(
        address account,
        IOrderBookCore.Side side,
        uint16 tick
    ) external onlyLiquidationModule returns (uint96 removedLots) {
        address mm = marketMakerModule;
        if (mm != address(0)) {
            IMarketMakerLiquidationCleanup(mm).liquidationForgetManagedQuote(
                account,
                side,
                tick
            );
        }
        removedLots = core.moduleForceCancelQuote(account, side, tick);
    }

    function liquidationTake(
        address account,
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 lots
    ) external onlyLiquidationModule returns (uint96 filledLots) {
        filledLots = core.moduleTake(
            account,
            side,
            limitTick,
            lots,
            IOrderBookCore.FillPolicy.IOC,
            true,
            false
        );
    }

    function liquidationCoverBadDebt(address account, uint256 requested)
        external
        onlyLiquidationModule
        returns (uint256 covered)
    {
        covered = core.moduleCoverBadDebt(account, requested);
    }

    function liquidationPayReward(address liquidator, uint256 requested)
        external
        onlyLiquidationModule
        returns (uint256 paid)
    {
        paid = core.modulePayLiquidationReward(liquidator, requested);
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

        filledLots = _take(
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

    function placeTriggeredPostOnlyOrder(
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
        conditionalOrders[orderId].flags |= FLAG_POST_ONLY;
        emit TriggeredPostOnlyOrderPlaced(orderId);
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
            riskCeiling = _reserveExposure(account, side, lots);
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

    function setConditionalExpiry(uint64 orderId, uint64 expiry) external {
        ConditionalOrder storage order = conditionalOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert Unauthorized();
        if (!_active(order) && !restingLinks[orderId].active) revert OrderInactive();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        conditionalExpiry[orderId] = expiry;
        emit ConditionalExpirySet(orderId, expiry);
    }

    function expireConditionalOrder(uint64 orderId) external {
        ConditionalOrder storage order = conditionalOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        uint64 expiry = conditionalExpiry[orderId];
        if (expiry == 0 || block.timestamp < expiry) revert InvalidExpiry();

        if (restingLinks[orderId].active) {
            _cancelRestingOrder(orderId, false);
        } else {
            _cancelConditional(orderId, true, false);
        }
        delete conditionalExpiry[orderId];
        emit ConditionalOrderExpired(orderId);
    }

    function cancelConditionalOrder(uint64 orderId) external {
        ConditionalOrder storage order = conditionalOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert Unauthorized();

        if (!_active(order) && restingLinks[orderId].active) {
            _cancelRestingOrder(orderId, false);
            return;
        }

        _cancelConditional(orderId, true, false);
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
        uint64 expiry = conditionalExpiry[orderId];
        if (expiry != 0 && block.timestamp >= expiry) revert OrderExpired();

        ConditionalOrder memory order = stored;
        uint16 mark = core.currentMarkTick();

        bool triggerAbove = (order.flags & FLAG_TRIGGER_ABOVE) != 0;
        if (triggerAbove ? mark < order.triggerTick : mark > order.triggerTick) {
            revert TriggerNotSatisfied();
        }

        uint64 parentOfExit = otoParent[orderId];
        if (parentOfExit != 0 && restingLinks[parentOfExit].active) {
            _syncRestingOrder(parentOfExit);
            _cancelRestingOrder(parentOfExit, false);
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
            filledLots = _take(
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
                    _releaseExposure(order.owner, order.side, unfilled);
                }
            }

            if (filledLots != 0) {
                _resizeOTOChildren(orderId, order.owner, filledLots);
            } else {
                _cancelOTOChildren(orderId, false);
            }
        }

        if (!restingLinks[orderId].active) {
            activeAdvancedCount[order.owner] -= 1;
            delete conditionalExpiry[orderId];
        }

        _unlinkOTOChild(orderId);

        uint64 sibling = order.sibling;
        if (sibling != 0) _cancelConditional(sibling, true, false);

        emit ConditionalOrderExecuted(orderId, filledLots);
    }

    function _executeTriggeredLimit(uint64 orderId, ConditionalOrder memory order)
        internal
        returns (uint96 filledLots)
    {
        bool postOnly = (order.flags & FLAG_POST_ONLY) != 0;
        if (!postOnly) {
            filledLots = _take(
                order.owner,
                order.side,
                order.limitTick,
                order.lots,
                IOrderBookCore.FillPolicy.IOC,
                false,
                true
            );
        }

        uint96 restingLots = order.lots - filledLots;

        if (restingLots != 0) {
            uint128 shares = _addLiquidity(
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
            _cancelOTOChildren(orderId, false);
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

        removedLots = _cancelRestingOrder(parentOrderId, false);
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
            uint256 numerator =
                uint256(link.shares) * uint256(remainingLots);
            currentClaim = uint96(
                (numerator + uint256(totalShares) - 1) / uint256(totalShares)
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
            // A fully consumed resting parent must materialize its maker fill before
            // the link is retired. Otherwise activated reduce-only OTO exits can
            // observe a stale active core quote and fail ReduceOnlyViolation.
            core.moduleSettle(parent.owner, parent.side, parent.limitTick);
            core.moduleUnlockShares(
                parent.owner,
                parent.side,
                parent.limitTick,
                link.generation,
                link.shares
            );
            delete restingLinks[parentOrderId];
            activeAdvancedCount[parent.owner] -= 1;
            delete conditionalExpiry[parentOrderId];
        }
    }

    function _cancelRestingOrder(uint64 parentOrderId, bool liquidation)
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

        uint96 cumulativeFilledLots = live.cumulativeFilledLots;

        removedLots = core.moduleRemoveLockedShares(
            parent.owner,
            parent.side,
            parent.limitTick,
            live.generation,
            live.shares
        );

        delete restingLinks[parentOrderId];
        activeAdvancedCount[parent.owner] -= 1;
        delete conditionalExpiry[parentOrderId];

        // If the entry never filled, its dormant OTO exits have no exposure to
        // protect and must be retired with the parent. Partially filled parents
        // keep their activated exits alive for the realized position.
        if (cumulativeFilledLots == 0) {
            _cancelOTOChildren(parentOrderId, liquidation);
        }

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
            riskCeiling = _reserveExposure(msg.sender, side, lots);
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

    function setTrailingExpiry(uint64 orderId, uint64 expiry) external {
        TrailingOrder storage order = trailingOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert Unauthorized();
        if ((order.flags & FLAG_ACTIVE) == 0) revert OrderInactive();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        trailingExpiry[orderId] = expiry;
        emit TrailingExpirySet(orderId, expiry);
    }

    function expireTrailingOrder(uint64 orderId) external {
        TrailingOrder storage order = trailingOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        uint64 expiry = trailingExpiry[orderId];
        if (expiry == 0 || block.timestamp < expiry) revert InvalidExpiry();
        _cancelTrailing(orderId, true, false);
        delete trailingExpiry[orderId];
        emit TrailingOrderExpired(orderId);
    }

    function cancelTrailingOrder(uint64 orderId) external {
        TrailingOrder storage order = trailingOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if (order.owner != msg.sender) revert Unauthorized();

        _cancelTrailing(orderId, true, false);
    }

    function executeTrailingOrder(uint64 orderId) external returns (uint96 filledLots) {
        TrailingOrder storage stored = trailingOrders[orderId];
        if (stored.owner == address(0)) revert OrderNotFound();
        if ((stored.flags & FLAG_ACTIVE) == 0) revert OrderInactive();
        uint64 expiry = trailingExpiry[orderId];
        if (expiry != 0 && block.timestamp >= expiry) revert OrderExpired();

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
        delete trailingExpiry[orderId];

        filledLots = _take(
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
                _releaseExposure(order.owner, order.side, unfilled);
            }
        }

        emit TrailingOrderExecuted(orderId, filledLots, highTick, lowTick);
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

    function _cancelOTOChildren(uint64 parentOrderId, bool liquidation) internal {
        uint64 first = otoChildOne[parentOrderId];
        uint64 second = otoChildTwo[parentOrderId];

        if (first != 0) {
            _cancelConditional(first, true, liquidation);
            delete otoParent[first];
            delete otoChildMaxLots[first];
        }

        if (second != 0) {
            _cancelConditional(second, true, liquidation);
            delete otoParent[second];
            delete otoChildMaxLots[second];
        }

        delete otoChildOne[parentOrderId];
        delete otoChildTwo[parentOrderId];
    }

    function _unlinkOTOChild(uint64 orderId) internal {
        uint64 parentId = otoParent[orderId];
        if (parentId == 0) return;

        if (otoChildOne[parentId] == orderId) {
            otoChildOne[parentId] = 0;
        } else if (otoChildTwo[parentId] == orderId) {
            otoChildTwo[parentId] = 0;
        }

        delete otoParent[orderId];
        delete otoChildMaxLots[orderId];
    }

    function _cancelConditional(uint64 orderId, bool releaseRisk, bool liquidation) internal {
        ConditionalOrder storage order = conditionalOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();

        bool active = _active(order);
        bool dormant = _dormant(order);
        if (!active && !dormant) return;

        order.flags &= ~(FLAG_ACTIVE | FLAG_DORMANT);
        activeAdvancedCount[order.owner] -= 1;

        bool reduceOnly = (order.flags & FLAG_REDUCE_ONLY) != 0;
        if (releaseRisk && !reduceOnly) {
            _releaseExposure(order.owner, order.side, order.lots, liquidation);
        }

        uint64 sibling = order.sibling;
        if (sibling != 0) {
            ConditionalOrder storage other = conditionalOrders[sibling];
            if (other.owner != address(0) && other.sibling == orderId) {
                other.sibling = 0;
            }
            order.sibling = 0;
        }

        _unlinkOTOChild(orderId);

        if (otoChildOne[orderId] != 0 || otoChildTwo[orderId] != 0) {
            _cancelOTOChildren(orderId, liquidation);
        }

        delete conditionalExpiry[orderId];
        emit ConditionalOrderCancelled(orderId);
    }

    function _cancelTrailing(uint64 orderId, bool releaseRisk, bool liquidation) internal {
        TrailingOrder storage order = trailingOrders[orderId];
        if (order.owner == address(0)) revert OrderNotFound();
        if ((order.flags & FLAG_ACTIVE) == 0) return;

        order.flags &= ~FLAG_ACTIVE;
        activeAdvancedCount[order.owner] -= 1;

        bool reduceOnly = (order.flags & FLAG_REDUCE_ONLY) != 0;
        if (releaseRisk && !reduceOnly) {
            _releaseExposure(order.owner, order.side, order.lots, liquidation);
        }

        delete trailingExpiry[orderId];
        emit TrailingOrderCancelled(orderId);
    }

    function _reserveExposure(
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) internal returns (uint16 riskCeilingTick) {
        IPortfolioAdmissionGateway controller = portfolioController;
        if (address(controller) == address(0)) {
            return core.moduleReserveExposure(account, side, lots);
        }
        return controller.gatewayReserveExposure(
            portfolioMarketIndex,
            account,
            side,
            lots
        );
    }

    function _releaseExposure(
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) internal {
        _releaseExposure(account, side, lots, false);
    }

    function _releaseExposure(
        address account,
        IOrderBookCore.Side side,
        uint96 lots,
        bool liquidation
    ) internal {
        IPortfolioAdmissionGateway controller = portfolioController;
        if (address(controller) == address(0)) {
            core.moduleReleaseExposure(account, side, lots);
            return;
        }
        if (liquidation) {
            controller.gatewayLiquidationReleaseExposure(
                portfolioMarketIndex,
                account,
                side,
                lots
            );
        } else {
            controller.gatewayReleaseExposure(
                portfolioMarketIndex,
                account,
                side,
                lots
            );
        }
    }

    function _take(
        address account,
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 lots,
        IOrderBookCore.FillPolicy policy,
        bool reduceOnly,
        bool preReserved
    ) internal returns (uint96 filledLots) {
        IPortfolioAdmissionGateway controller = portfolioController;
        if (address(controller) == address(0) || reduceOnly) {
            return core.moduleTake(
                account,
                side,
                limitTick,
                lots,
                policy,
                reduceOnly,
                preReserved
            );
        }
        return controller.gatewayTake(
            portfolioMarketIndex,
            account,
            side,
            limitTick,
            lots,
            policy,
            reduceOnly,
            preReserved
        );
    }

    function _addLiquidity(
        address account,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots,
        uint16 reservedRiskCeiling
    ) internal returns (uint128 mintedShares) {
        IPortfolioAdmissionGateway controller = portfolioController;
        if (address(controller) == address(0)) {
            return core.moduleAddLiquidity(
                account,
                side,
                tick,
                lots,
                reservedRiskCeiling
            );
        }
        return controller.gatewayAddLiquidity(
            portfolioMarketIndex,
            account,
            side,
            tick,
            lots,
            reservedRiskCeiling
        );
    }

    function _active(ConditionalOrder storage order) internal view returns (bool) {
        return (order.flags & FLAG_ACTIVE) != 0;
    }

    function _dormant(ConditionalOrder storage order) internal view returns (bool) {
        return (order.flags & FLAG_DORMANT) != 0;
    }
}


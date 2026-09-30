// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IMarkOracle} from "./interfaces/IMarkOracle.sol";

/// @title ProRataOrderBook
/// @notice Experimental fully-on-chain order book kernel.
/// @dev Best-price priority across ticks, pro-rata allocation within a tick.
///      This prototype intentionally excludes custody, fees, liquidation and oracle wiring.
contract ProRataOrderBook {
    uint256 public constant INITIAL_SHARE_SCALE = 1_000_000;
    uint256 public constant ACCUMULATOR_SCALE = 1 << 96;
    int256 public constant FUNDING_SCALE = 1e18;

    enum Side {
        Bid,
        Ask
    }

    enum FillPolicy {
        IOC,
        FOK
    }

    /// @dev Fits in one storage slot.
    struct TickPool {
        uint128 totalShares;
        uint96 remainingLots;
        uint32 generation;
    }

    /// @dev Fits in one storage slot.
    /// claimLots is the maker's last materialized unfilled entitlement.
    struct MakerQuote {
        uint128 shares;
        uint96 claimLots;
        uint32 generation;
    }

    /// @dev Three int80 values fit in one storage slot. All position-changing paths
    ///      use _positionAmount() so narrowing is checked.
    struct AccountRisk {
        int80 settledPosition;
        int80 minPosition;
        int80 maxPosition;
    }

    struct RiskConfig {
        uint16 markTick;
        uint16 executionBandTicks;
        uint16 initialMarginBps;
        bool enabled;
    }

    /// @dev Triggered orders are stored fully on-chain and executed permissionlessly.
    /// flags: bit0 active, bit1 triggerAboveOrEqual, bit2 reduceOnly, bit3 restingLimit.
    struct ConditionalOrder {
        address owner;
        uint96 lots;
        uint64 sibling;
        uint16 triggerTick;
        uint16 limitTick;
        uint16 riskCeilingTick;
        Side side;
        FillPolicy policy;
        uint8 flags;
    }

    error ZeroAmount();
    error CrossesBook();
    error InsufficientLiquidity();
    error InvalidShareAmount();
    error StaleQuote();
    error Overflow();
    error Unauthorized();
    error InvalidRiskConfig();
    error InsufficientCollateral();
    error TokenTransferFailed();
    error UnsupportedTokenBehavior();
    error SettlementAlreadyConfigured();
    error UnsettledQuotes();
    error ReduceOnlyViolation();
    error ConditionalOrderNotFound();
    error ConditionalOrderInactive();
    error TriggerNotSatisfied();
    error InvalidOCO();
    error InvalidLiquidationConfig();
    error NotLiquidatable();
    error InvalidLiquidationInput();
    error PositionOverflow();

    mapping(Side => mapping(uint16 => TickPool)) public pools;
    mapping(address => mapping(Side => mapping(uint16 => MakerQuote))) public quotes;
    mapping(address => AccountRisk) public accountRisk;
    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public reservedMargin;
    mapping(address => uint16) public accountRiskCeilingTick;
    mapping(Side => mapping(uint16 => uint16)) public poolRiskCeilingTick;

    // Lazy funding attribution. These mappings intentionally sit outside TickPool/MakerQuote
    // so the hot liquidity structs remain one slot each.
    int128 public fundingIndexX18;
    mapping(Side => mapping(uint16 => int256)) public fundingEntryPerShareX96;
    mapping(Side => mapping(uint16 => mapping(uint32 => int256))) public closedFundingEntryPerShareX96;
    mapping(address => mapping(Side => mapping(uint16 => int256))) public quoteFundingCheckpointX96;
    mapping(address => int128) public accountFundingCheckpointX18;
    mapping(address => int256) public fundingCashflow;
    mapping(address => int256) public tradeCashflow;
    mapping(address => uint32) public activeQuoteCount;
    mapping(address => uint32) public activeConditionalCount;
    mapping(Side => mapping(uint16 => mapping(uint32 => uint128))) public closedFundingOutstandingShares;

    uint16 public maintenanceMarginBps;
    uint64 public nextConditionalOrderId = 1;
    mapping(uint64 => ConditionalOrder) public conditionalOrders;
    RiskConfig public riskConfig;
    IERC20Minimal public collateralToken;
    IMarkOracle public markOracle;
    address public immutable owner;

    // 65,536 ticks => 256 words of 256 ticks.
    mapping(Side => mapping(uint8 => uint256)) internal _tickWords;
    mapping(Side => uint256) internal _occupiedWords;

    uint256 public totalAddedLots;
    uint256 public totalRemovedLots;
    uint256 public totalExecutedLots;

    constructor() {
        owner = msg.sender;
    }

    event LiquidityAdded(
        address indexed maker,
        Side indexed side,
        uint16 indexed tick,
        uint96 lots,
        uint128 shares,
        uint32 generation
    );
    event LiquidityRemoved(
        address indexed maker,
        Side indexed side,
        uint16 indexed tick,
        uint96 lots,
        uint128 shares,
        uint32 generation
    );
    event MakerSettled(
        address indexed maker,
        Side indexed side,
        uint16 indexed tick,
        uint96 filledLots,
        uint32 generation
    );
    event Trade(
        address indexed taker,
        Side indexed takerSide,
        uint16 indexed tick,
        uint96 lots
    );
    event RiskConfigured(uint16 markTick, uint16 executionBandTicks, uint16 initialMarginBps);
    event CollateralCredited(address indexed account, uint256 amount);
    event CollateralDebited(address indexed account, uint256 amount);
    event SettlementConfigured(address indexed collateralToken, address indexed markOracle);
    event FundingIndexUpdated(int128 fundingIndexX18);
    event FundingSettled(address indexed account, int256 cashflowDelta);
    event ConditionalOrderPlaced(
        uint64 indexed orderId,
        address indexed owner,
        Side side,
        uint16 triggerTick,
        uint16 limitTick,
        uint96 lots,
        bool triggerAboveOrEqual,
        bool reduceOnly
    );
    event ConditionalOrderCancelled(uint64 indexed orderId);
    event ConditionalOrderExecuted(uint64 indexed orderId, uint96 filledLots);
    event TriggeredLimitActivated(
        uint64 indexed orderId,
        uint96 takerFilledLots,
        uint96 restingLots,
        uint128 restingShares
    );
    event OCOLinked(uint64 indexed firstOrderId, uint64 indexed secondOrderId);
    event LiquidationConfigured(uint16 maintenanceMarginBps);
    event Liquidated(
        address indexed liquidator,
        address indexed account,
        uint96 closedLots,
        int256 equityBefore
    );

    function configureSettlement(address token, address oracle) external {
        if (msg.sender != owner) revert Unauthorized();
        if (address(collateralToken) != address(0) || address(markOracle) != address(0)) {
            revert SettlementAlreadyConfigured();
        }
        if (token == address(0) || oracle == address(0)) revert InvalidRiskConfig();

        collateralToken = IERC20Minimal(token);
        markOracle = IMarkOracle(oracle);

        emit SettlementConfigured(token, oracle);
    }

    function configureRisk(uint16 markTick, uint16 executionBandTicks, uint16 initialMarginBps)
        external
    {
        if (msg.sender != owner) revert Unauthorized();
        if (initialMarginBps == 0 || initialMarginBps > 10_000) revert InvalidRiskConfig();
        riskConfig = RiskConfig({
            markTick: markTick,
            executionBandTicks: executionBandTicks,
            initialMarginBps: initialMarginBps,
            enabled: true
        });
        emit RiskConfigured(markTick, executionBandTicks, initialMarginBps);
    }

    function configureLiquidation(uint16 maintenanceBps) external {
        if (msg.sender != owner) revert Unauthorized();
        if (
            maintenanceBps == 0 || maintenanceBps > 10_000
                || (riskConfig.enabled && maintenanceBps >= riskConfig.initialMarginBps)
        ) {
            revert InvalidLiquidationConfig();
        }

        maintenanceMarginBps = maintenanceBps;
        emit LiquidationConfigured(maintenanceBps);
    }

    function setFundingIndex(int128 nextFundingIndexX18) external {
        if (msg.sender != owner) revert Unauthorized();
        fundingIndexX18 = nextFundingIndexX18;
        emit FundingIndexUpdated(nextFundingIndexX18);
    }

    function setMarkTick(uint16 markTick) external {
        if (msg.sender != owner) revert Unauthorized();
        RiskConfig storage r = riskConfig;
        if (!r.enabled) revert InvalidRiskConfig();
        r.markTick = markTick;
    }

    /// @notice Deposit collateral. Uses real ERC-20 custody once settlement is configured.
    /// @dev Before settlement configuration this preserves the research-kernel accounting mode
    ///      so core matching tests remain independently runnable.
    function depositCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        IERC20Minimal token = collateralToken;
        if (address(token) != address(0)) {
            uint256 beforeBalance = token.balanceOf(address(this));
            if (!token.transferFrom(msg.sender, address(this), amount)) revert TokenTransferFailed();
            uint256 received = token.balanceOf(address(this)) - beforeBalance;
            if (received != amount) revert UnsupportedTokenBehavior();
        }

        collateralBalance[msg.sender] += amount;
        emit CollateralCredited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (
            riskConfig.enabled
                && (activeQuoteCount[msg.sender] != 0 || activeConditionalCount[msg.sender] != 0)
        ) revert UnsettledQuotes();

        _settleExistingPositionFunding(msg.sender);

        uint256 balance = collateralBalance[msg.sender];
        if (amount > balance) revert InsufficientCollateral();

        int256 equityAfter =
            int256(balance - amount) + fundingCashflow[msg.sender];
        if (equityAfter < int256(reservedMargin[msg.sender])) revert InsufficientCollateral();

        collateralBalance[msg.sender] = balance - amount;

        IERC20Minimal token = collateralToken;
        if (address(token) != address(0)) {
            if (!token.transfer(msg.sender, amount)) revert TokenTransferFailed();
        }

        emit CollateralDebited(msg.sender, amount);
    }

    function placeConditionalOrder(
        Side side,
        bool triggerAboveOrEqual,
        uint16 triggerTick,
        uint16 limitTick,
        uint96 lots,
        FillPolicy policy,
        bool reduceOnly
    ) external returns (uint64 orderId) {
        if (lots == 0) revert ZeroAmount();

        uint16 riskCeiling;
        if (!reduceOnly) {
            _expandRisk(msg.sender, side, lots);

            if (riskConfig.enabled) {
                uint256 ceiling =
                    uint256(_currentMarkTick()) + uint256(riskConfig.executionBandTicks);
                if (ceiling > type(uint16).max) ceiling = type(uint16).max;
                riskCeiling = uint16(ceiling);

                if (riskCeiling > accountRiskCeilingTick[msg.sender]) {
                    accountRiskCeilingTick[msg.sender] = riskCeiling;
                }
            }

            _refreshReservedMargin(msg.sender);
        }

        orderId = nextConditionalOrderId++;
        uint8 flags = 1;
        if (triggerAboveOrEqual) flags |= 2;
        if (reduceOnly) flags |= 4;

        conditionalOrders[orderId] = ConditionalOrder({
            owner: msg.sender,
            lots: lots,
            sibling: 0,
            triggerTick: triggerTick,
            limitTick: limitTick,
            riskCeilingTick: riskCeiling,
            side: side,
            policy: policy,
            flags: flags
        });

        activeConditionalCount[msg.sender] += 1;

        emit ConditionalOrderPlaced(
            orderId,
            msg.sender,
            side,
            triggerTick,
            limitTick,
            lots,
            triggerAboveOrEqual,
            reduceOnly
        );
    }

    function placeTriggeredLimitOrder(
        Side side,
        bool triggerAboveOrEqual,
        uint16 triggerTick,
        uint16 limitTick,
        uint96 lots
    ) external returns (uint64 orderId) {
        if (lots == 0) revert ZeroAmount();

        _expandRisk(msg.sender, side, lots);

        uint16 riskCeiling;
        if (riskConfig.enabled) {
            uint256 ceiling =
                uint256(_currentMarkTick()) + uint256(riskConfig.executionBandTicks);
            if (ceiling > type(uint16).max) ceiling = type(uint16).max;
            riskCeiling = uint16(ceiling);

            if (riskCeiling > accountRiskCeilingTick[msg.sender]) {
                accountRiskCeilingTick[msg.sender] = riskCeiling;
            }
        }
        _refreshReservedMargin(msg.sender);

        orderId = nextConditionalOrderId++;
        uint8 flags = 1 | 8;
        if (triggerAboveOrEqual) flags |= 2;

        conditionalOrders[orderId] = ConditionalOrder({
            owner: msg.sender,
            lots: lots,
            sibling: 0,
            triggerTick: triggerTick,
            limitTick: limitTick,
            riskCeilingTick: riskCeiling,
            side: side,
            policy: FillPolicy.IOC,
            flags: flags
        });

        activeConditionalCount[msg.sender] += 1;

        emit ConditionalOrderPlaced(
            orderId,
            msg.sender,
            side,
            triggerTick,
            limitTick,
            lots,
            triggerAboveOrEqual,
            false
        );
    }

    function cancelConditionalOrder(uint64 orderId) external {
        ConditionalOrder storage order = conditionalOrders[orderId];
        if (order.owner == address(0)) revert ConditionalOrderNotFound();
        if (order.owner != msg.sender) revert Unauthorized();
        _cancelConditional(orderId, true);
    }

    function linkOCO(uint64 firstOrderId, uint64 secondOrderId) external {
        if (firstOrderId == secondOrderId) revert InvalidOCO();

        ConditionalOrder storage first = conditionalOrders[firstOrderId];
        ConditionalOrder storage second = conditionalOrders[secondOrderId];

        if (first.owner == address(0) || second.owner == address(0)) {
            revert ConditionalOrderNotFound();
        }
        if (first.owner != msg.sender || second.owner != msg.sender) revert Unauthorized();
        if (!_conditionalActive(first) || !_conditionalActive(second)) revert ConditionalOrderInactive();
        if (first.sibling != 0 || second.sibling != 0) revert InvalidOCO();

        first.sibling = secondOrderId;
        second.sibling = firstOrderId;

        emit OCOLinked(firstOrderId, secondOrderId);
    }

    function executeConditionalOrder(uint64 orderId) external returns (uint96 filledLots) {
        ConditionalOrder storage stored = conditionalOrders[orderId];
        if (stored.owner == address(0)) revert ConditionalOrderNotFound();
        if (!_conditionalActive(stored)) revert ConditionalOrderInactive();

        ConditionalOrder memory order = stored;
        uint16 mark = _currentMarkTick();
        bool triggerAboveOrEqual = (order.flags & 2) != 0;
        if (triggerAboveOrEqual ? mark < order.triggerTick : mark > order.triggerTick) {
            revert TriggerNotSatisfied();
        }

        bool reduceOnly = (order.flags & 4) != 0;
        if (reduceOnly) {
            if (activeQuoteCount[order.owner] != 0) revert UnsettledQuotes();
        } else if (order.riskCeilingTick != 0 && mark > order.riskCeilingTick) {
            revert InvalidRiskConfig();
        }

        bool restingLimit = (order.flags & 8) != 0;

        stored.flags &= ~uint8(1);
        activeConditionalCount[order.owner] -= 1;

        if (restingLimit) {
            uint96 restingLots;
            uint128 restingShares;
            (filledLots, restingLots, restingShares) = _activateTriggeredLimit(order);
            emit TriggeredLimitActivated(orderId, filledLots, restingLots, restingShares);
        } else {
            filledLots = _takeFor(
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
                if (unfilled != 0) _shrinkRisk(order.owner, order.side, unfilled);
                _refreshReservedMargin(order.owner);
            }
        }

        uint64 sibling = order.sibling;
        if (sibling != 0) _cancelConditional(sibling, true);

        emit ConditionalOrderExecuted(orderId, filledLots);
    }

    function conditionalOrderActive(uint64 orderId) external view returns (bool) {
        ConditionalOrder storage order = conditionalOrders[orderId];
        return order.owner != address(0) && _conditionalActive(order);
    }

    function addLiquidity(Side side, uint16 tick, uint96 lots)
        external
        returns (uint128 mintedShares)
    {
        mintedShares = _addLiquidityFor(msg.sender, side, tick, lots, false, 0, true);
    }

    /// @notice Burn maker shares and withdraw their current pro-rata unfilled lots.
    /// @dev O(1) relative to maker count; there are no linked-list removals or tombstones.
    function _activateTriggeredLimit(ConditionalOrder memory order)
        internal
        returns (uint96 filledLots, uint96 restingLots, uint128 restingShares)
    {
        Side makerSide = order.side == Side.Bid ? Side.Ask : Side.Bid;

        if (_availableThrough(makerSide, order.limitTick, order.lots) != 0) {
            uint256 notional;
            (filledLots, notional) =
                _match(order.owner, order.side, makerSide, order.limitTick, order.lots);

            if (filledLots != 0) {
                _applyImmediateTakerFill(
                    order.owner, order.side, filledLots, notional, true
                );
            }
        }

        restingLots = order.lots - filledLots;
        if (restingLots != 0) {
            // If non-executable raw opposite liquidity still crosses the limit, activation
            // waits rather than creating a crossed resting book.
            _assertPostOnly(order.side, order.limitTick);

            restingShares = _addLiquidityFor(
                order.owner,
                order.side,
                order.limitTick,
                restingLots,
                true,
                order.riskCeilingTick,
                false
            );
        }

        _refreshReservedMargin(order.owner);
    }

    function _addLiquidityFor(
        address maker,
        Side side,
        uint16 tick,
        uint96 lots,
        bool preReserved,
        uint16 reservedRiskCeiling,
        bool enforcePostOnly
    ) internal returns (uint128 mintedShares) {
        if (lots == 0) revert ZeroAmount();
        if (enforcePostOnly) _assertPostOnly(side, tick);
        _settle(maker, side, tick);

        TickPool storage p = pools[side][tick];
        MakerQuote storage q = quotes[maker][side][tick];

        bool wasEmpty = p.remainingLots == 0;
        bool isNewMakerQuote = q.shares == 0;

        uint16 riskCeiling;
        if (riskConfig.enabled) {
            uint16 mark = _currentMarkTick();

            if (wasEmpty) {
                if (preReserved) {
                    if (reservedRiskCeiling == 0 || mark > reservedRiskCeiling) {
                        revert InvalidRiskConfig();
                    }
                    riskCeiling = reservedRiskCeiling;
                } else {
                    uint256 ceiling =
                        uint256(mark) + uint256(riskConfig.executionBandTicks);
                    if (ceiling > type(uint16).max) ceiling = type(uint16).max;
                    riskCeiling = uint16(ceiling);
                }
                poolRiskCeilingTick[side][tick] = riskCeiling;
            } else {
                riskCeiling = poolRiskCeilingTick[side][tick];
                if (mark > riskCeiling) revert InvalidRiskConfig();
                if (preReserved && riskCeiling > reservedRiskCeiling) {
                    revert InvalidRiskConfig();
                }
            }

            if (riskCeiling > accountRiskCeilingTick[maker]) {
                accountRiskCeilingTick[maker] = riskCeiling;
            }
        }

        if (p.totalShares == 0) {
            uint256 raw = uint256(lots) * INITIAL_SHARE_SCALE;
            if (raw > type(uint128).max) revert Overflow();
            mintedShares = uint128(raw);
        } else {
            uint256 raw =
                uint256(lots) * uint256(p.totalShares) / uint256(p.remainingLots);
            if (raw == 0 || raw > type(uint128).max) revert InvalidShareAmount();
            mintedShares = uint128(raw);
        }

        uint256 nextShares = uint256(p.totalShares) + mintedShares;
        uint256 nextLots = uint256(p.remainingLots) + lots;
        if (nextShares > type(uint128).max || nextLots > type(uint96).max) revert Overflow();

        p.totalShares = uint128(nextShares);
        p.remainingLots = uint96(nextLots);

        if (q.shares == 0) {
            q.generation = p.generation;
            quoteFundingCheckpointX96[maker][side][tick] =
                fundingEntryPerShareX96[side][tick];
        } else if (q.generation != p.generation) {
            revert StaleQuote();
        }

        q.shares += mintedShares;
        q.claimLots += lots;
        if (isNewMakerQuote) activeQuoteCount[maker] += 1;

        if (!preReserved) {
            _expandRisk(maker, side, lots);
            _refreshReservedMargin(maker);
        }

        totalAddedLots += lots;
        if (wasEmpty) _setOccupied(side, tick, true);

        emit LiquidityAdded(maker, side, tick, lots, mintedShares, p.generation);
    }

    function removeShares(Side side, uint16 tick, uint128 sharesToBurn)
        external
        returns (uint96 removedLots)
    {
        if (sharesToBurn == 0) revert ZeroAmount();
        _settle(msg.sender, side, tick);

        TickPool storage p = pools[side][tick];
        MakerQuote storage q = quotes[msg.sender][side][tick];
        if (q.shares == 0 || q.generation != p.generation) revert StaleQuote();
        if (sharesToBurn > q.shares) revert InvalidShareAmount();

        uint256 redeemed =
            uint256(sharesToBurn) * uint256(p.remainingLots) / uint256(p.totalShares);
        if (redeemed == 0 || redeemed > type(uint96).max) revert InvalidShareAmount();
        removedLots = uint96(redeemed);

        p.totalShares -= sharesToBurn;
        p.remainingLots -= removedLots;
        q.shares -= sharesToBurn;

        if (removedLots > q.claimLots) revert InvalidShareAmount();
        q.claimLots -= removedLots;

        _shrinkRisk(msg.sender, side, removedLots);
        _refreshReservedMargin(msg.sender);
        totalRemovedLots += removedLots;

        if (q.shares == 0) {
            delete quotes[msg.sender][side][tick];
            delete quoteFundingCheckpointX96[msg.sender][side][tick];
            activeQuoteCount[msg.sender] -= 1;
        }

        if (p.totalShares == 0) {
            if (p.remainingLots != 0) revert InvalidShareAmount();
            _setOccupied(side, tick, false);
            delete poolRiskCeilingTick[side][tick];
            unchecked {
                ++p.generation;
            }
        }

        emit LiquidityRemoved(msg.sender, side, tick, removedLots, sharesToBurn, p.generation);
    }

    /// @notice Materialize lazy maker fills for one side/tick.
    function settle(Side side, uint16 tick) external returns (uint96 filledLots) {
        filledLots = _settle(msg.sender, side, tick);
        _settleExistingPositionFunding(msg.sender);
    }

    function settleFunding() external returns (int256 cashflow) {
        _settleExistingPositionFunding(msg.sender);
        cashflow = fundingCashflow[msg.sender];
    }

    function accountEquity(address account) public view returns (int256 equity) {
        AccountRisk memory a = accountRisk[account];

        int256 pendingFunding =
            -(int256(a.settledPosition)
                * (int256(fundingIndexX18) - int256(accountFundingCheckpointX18[account]))
                / FUNDING_SCALE);

        equity = int256(collateralBalance[account]) + tradeCashflow[account]
            + fundingCashflow[account] + pendingFunding
            + int256(a.settledPosition) * int256(uint256(_currentMarkTick()));
    }

    function maintenanceRequirement(address account) public view returns (uint256) {
        uint16 maintenanceBps = maintenanceMarginBps;
        if (maintenanceBps == 0) return 0;

        int80 position = accountRisk[account].settledPosition;
        uint256 absPosition =
            position < 0 ? uint256(uint80(-position)) : uint256(uint80(position));

        return absPosition * uint256(_currentMarkTick()) * uint256(maintenanceBps) / 10_000;
    }

    function isLiquidatable(address account) public view returns (bool) {
        if (maintenanceMarginBps == 0) return false;
        if (activeQuoteCount[account] != 0 || activeConditionalCount[account] != 0) return false;
        if (accountRisk[account].settledPosition == 0) return false;

        return accountEquity(account) < int256(maintenanceRequirement(account));
    }

    function liquidate(
        address account,
        Side[] calldata makerSides,
        uint16[] calldata makerTicks,
        uint64[] calldata conditionalIds
    ) external returns (uint96 closedLots) {
        if (maintenanceMarginBps == 0) revert InvalidLiquidationConfig();
        if (makerSides.length != makerTicks.length) revert InvalidLiquidationInput();

        for (uint256 i; i < makerTicks.length; ++i) {
            _forceCancelMakerQuote(account, makerSides[i], makerTicks[i]);
        }

        for (uint256 i; i < conditionalIds.length; ++i) {
            uint64 id = conditionalIds[i];
            ConditionalOrder storage order = conditionalOrders[id];
            if (order.owner == account && _conditionalActive(order)) {
                _cancelConditional(id, true);
            }
        }

        if (activeQuoteCount[account] != 0 || activeConditionalCount[account] != 0) {
            revert UnsettledQuotes();
        }

        _settleExistingPositionFunding(account);

        int256 equityBefore = accountEquity(account);
        if (equityBefore >= int256(maintenanceRequirement(account))) revert NotLiquidatable();

        int80 position = accountRisk[account].settledPosition;
        if (position > 0) {
            closedLots = _takeFor(
                account,
                Side.Ask,
                0,
                uint96(uint80(position)),
                FillPolicy.IOC,
                true,
                false
            );
        } else if (position < 0) {
            closedLots = _takeFor(
                account,
                Side.Bid,
                type(uint16).max,
                uint96(uint80(-position)),
                FillPolicy.IOC,
                true,
                false
            );
        } else {
            revert NotLiquidatable();
        }

        emit Liquidated(msg.sender, account, closedLots, equityBefore);
    }

    /// @notice Aggressively consume maker liquidity.
    /// @param takerSide Bid means buy from asks; Ask means sell into bids.
    /// @param limitTick Highest acceptable ask for a bid, or lowest acceptable bid for an ask.
    function take(Side takerSide, uint16 limitTick, uint96 lots, FillPolicy policy)
        external
        returns (uint96 filledLots)
    {
        filledLots = _takeFor(msg.sender, takerSide, limitTick, lots, policy, false, false);
    }

    function takeReduceOnly(Side takerSide, uint16 limitTick, uint96 lots, FillPolicy policy)
        external
        returns (uint96 filledLots)
    {
        if (activeQuoteCount[msg.sender] != 0) revert UnsettledQuotes();
        filledLots = _takeFor(msg.sender, takerSide, limitTick, lots, policy, true, false);
    }

    function _takeFor(
        address account,
        Side takerSide,
        uint16 limitTick,
        uint96 lots,
        FillPolicy policy,
        bool reduceOnly,
        bool preReserved
    ) internal returns (uint96 filledLots) {
        if (lots == 0) revert ZeroAmount();

        uint96 executableLots = lots;
        if (reduceOnly) {
            executableLots = _reduceOnlyLots(account, takerSide, lots);
            if (executableLots == 0) revert ReduceOnlyViolation();
            if (policy == FillPolicy.FOK && executableLots != lots) revert ReduceOnlyViolation();
        }

        Side makerSide = takerSide == Side.Bid ? Side.Ask : Side.Bid;
        if (
            policy == FillPolicy.FOK
                && _availableThrough(makerSide, limitTick, executableLots) < executableLots
        ) {
            revert InsufficientLiquidity();
        }

        uint256 notional;
        (filledLots, notional) =
            _match(account, takerSide, makerSide, limitTick, executableLots);

        if (policy == FillPolicy.FOK && filledLots != executableLots) {
            revert InsufficientLiquidity();
        }

        if (filledLots != 0) {
            _applyImmediateTakerFill(account, takerSide, filledLots, notional, preReserved);
        }
    }

    function _match(
        address account,
        Side takerSide,
        Side makerSide,
        uint16 limitTick,
        uint96 executableLots
    ) internal returns (uint96 filledLots, uint256 notional) {
        uint96 remaining = executableLots;

        while (remaining != 0) {
            (bool ok, uint16 tick) = _bestExecutableTick(makerSide);
            if (!ok || !_withinLimit(makerSide, tick, limitTick)) break;

            uint96 fill = _consumeTick(makerSide, tick, remaining);
            unchecked {
                remaining -= fill;
                filledLots += fill;
            }
            notional += uint256(fill) * uint256(tick);

            emit Trade(account, takerSide, tick, fill);
        }
    }

    function _consumeTick(Side makerSide, uint16 tick, uint96 requested)
        internal
        returns (uint96 fill)
    {
        TickPool storage p = pools[makerSide][tick];
        fill = requested < p.remainingLots ? requested : p.remainingLots;

        _recordFundingEntry(makerSide, tick, p.totalShares, fill);
        p.remainingLots -= fill;
        totalExecutedLots += fill;

        if (p.remainingLots != 0) return fill;

        uint32 oldGeneration = p.generation;
        closedFundingEntryPerShareX96[makerSide][tick][oldGeneration] =
            fundingEntryPerShareX96[makerSide][tick];
        closedFundingOutstandingShares[makerSide][tick][oldGeneration] = p.totalShares;
        fundingEntryPerShareX96[makerSide][tick] = 0;

        p.totalShares = 0;
        delete poolRiskCeilingTick[makerSide][tick];
        unchecked {
            ++p.generation;
        }
        _setOccupied(makerSide, tick, false);
    }

    function quoteState(address maker, Side side, uint16 tick)
        external
        view
        returns (
            uint128 shares,
            uint32 generation,
            uint96 currentClaimLots,
            uint96 pendingFillLots
        )
    {
        MakerQuote memory q = quotes[maker][side][tick];
        if (q.shares == 0) return (0, 0, 0, 0);

        TickPool memory p = pools[side][tick];

        shares = q.shares;
        generation = q.generation;

        if (q.generation != p.generation) {
            pendingFillLots = q.claimLots;
            return (shares, generation, 0, pendingFillLots);
        }

        currentClaimLots = _redeemableLots(q.shares, p.remainingLots, p.totalShares);
        if (currentClaimLots >= q.claimLots) {
            pendingFillLots = 0;
        } else {
            pendingFillLots = q.claimLots - currentClaimLots;
        }
    }

    function bestBid() external view returns (bool ok, uint16 tick) {
        return _bestTick(Side.Bid);
    }

    function bestAsk() external view returns (bool ok, uint16 tick) {
        return _bestTick(Side.Ask);
    }

    function occupiedWord(Side side, uint8 wordIndex) external view returns (uint256) {
        return _tickWords[side][wordIndex];
    }

    function occupiedWordBitmap(Side side) external view returns (uint256) {
        return _occupiedWords[side];
    }

    function _settle(address maker, Side side, uint16 tick)
        internal
        returns (uint96 filledLots)
    {
        MakerQuote storage q = quotes[maker][side][tick];
        if (q.shares == 0) return 0;

        TickPool storage p = pools[side][tick];

        if (q.generation != p.generation) {
            // A generation can only roll after every lot in that pool was consumed,
            // so the maker's full last materialized claim has filled.
            filledLots = q.claimLots;
            uint32 oldGeneration = q.generation;
            int256 finalFundingEntry =
                closedFundingEntryPerShareX96[side][tick][oldGeneration];
            _settleFundingForQuote(maker, side, tick, q.shares, filledLots, finalFundingEntry);
            _applyMakerFill(maker, side, tick, filledLots);
            _refreshReservedMargin(maker);

            uint128 outstanding = closedFundingOutstandingShares[side][tick][oldGeneration];
            if (outstanding >= q.shares) {
                outstanding -= q.shares;
                closedFundingOutstandingShares[side][tick][oldGeneration] = outstanding;
                if (outstanding == 0) {
                    delete closedFundingOutstandingShares[side][tick][oldGeneration];
                    delete closedFundingEntryPerShareX96[side][tick][oldGeneration];
                }
            }

            delete quotes[maker][side][tick];
            delete quoteFundingCheckpointX96[maker][side][tick];
            activeQuoteCount[maker] -= 1;
            emit MakerSettled(maker, side, tick, filledLots, oldGeneration);
            return filledLots;
        }

        uint96 currentClaim = _redeemableLots(q.shares, p.remainingLots, p.totalShares);

        // Share mint/burn rounding may occasionally make currentClaim one unit larger than
        // the last materialized claim. Treat that as pool dust/yield, never as a negative fill.
        if (currentClaim >= q.claimLots) {
            q.claimLots = currentClaim;
            return 0;
        }

        filledLots = q.claimLots - currentClaim;
        q.claimLots = currentClaim;

        int256 currentFundingEntry = fundingEntryPerShareX96[side][tick];
        _settleFundingForQuote(maker, side, tick, q.shares, filledLots, currentFundingEntry);
        quoteFundingCheckpointX96[maker][side][tick] = currentFundingEntry;

        _applyMakerFill(maker, side, tick, filledLots);
        _refreshReservedMargin(maker);
        emit MakerSettled(maker, side, tick, filledLots, q.generation);
    }

    function _redeemableLots(uint128 shares, uint96 remainingLots, uint128 totalShares)
        internal
        pure
        returns (uint96)
    {
        if (shares == 0 || remainingLots == 0 || totalShares == 0) return 0;
        uint256 lots = uint256(shares) * uint256(remainingLots) / uint256(totalShares);
        if (lots > type(uint96).max) revert Overflow();
        return uint96(lots);
    }

    function _recordFundingEntry(Side side, uint16 tick, uint128 totalShares, uint96 fillLots)
        internal
    {
        if (fillLots == 0 || totalShares == 0) return;

        uint256 fillPerShareX96 =
            uint256(fillLots) * ACCUMULATOR_SCALE / uint256(totalShares);
        int256 weighted =
            int256(fillPerShareX96) * int256(fundingIndexX18) / FUNDING_SCALE;

        fundingEntryPerShareX96[side][tick] += weighted;
    }

    function _settleFundingForQuote(
        address maker,
        Side side,
        uint16 tick,
        uint128 shares,
        uint96 filledLots,
        int256 finalFundingEntryPerShareX96
    ) internal {
        _settleExistingPositionFunding(maker);

        int256 weightedEntry =
            _weightedFundingEntry(maker, side, tick, shares, finalFundingEntryPerShareX96);
        int256 signedLots =
            side == Side.Bid ? int256(uint256(filledLots)) : -int256(uint256(filledLots));
        int256 currentFunding =
            signedLots * int256(fundingIndexX18) / FUNDING_SCALE;
        int256 entryFunding = signedLots == 0
            ? int256(0)
            : (signedLots > 0 ? weightedEntry : -weightedEntry);

        int256 cashflowDelta = entryFunding - currentFunding;
        if (cashflowDelta != 0) {
            fundingCashflow[maker] += cashflowDelta;
            emit FundingSettled(maker, cashflowDelta);
        }
        accountFundingCheckpointX18[maker] = fundingIndexX18;
    }

    function _weightedFundingEntry(
        address maker,
        Side side,
        uint16 tick,
        uint128 shares,
        int256 finalFundingEntryPerShareX96
    ) internal view returns (int256) {
        int256 deltaPerShare =
            finalFundingEntryPerShareX96 - quoteFundingCheckpointX96[maker][side][tick];
        return _divNearestSigned(
            int256(uint256(shares)) * deltaPerShare,
            int256(ACCUMULATOR_SCALE)
        );
    }

    function _settleExistingPositionFunding(address maker) internal {
        AccountRisk memory a = accountRisk[maker];
        int256 position = int256(a.settledPosition);
        int256 deltaIndex =
            int256(fundingIndexX18) - int256(accountFundingCheckpointX18[maker]);

        if (position != 0 && deltaIndex != 0) {
            int256 cashflowDelta = -(position * deltaIndex / FUNDING_SCALE);
            fundingCashflow[maker] += cashflowDelta;
            emit FundingSettled(maker, cashflowDelta);
        }

        accountFundingCheckpointX18[maker] = fundingIndexX18;
    }

    function _divNearestSigned(int256 numerator, int256 denominator)
        internal
        pure
        returns (int256)
    {
        int256 half = denominator / 2;
        if (numerator >= 0) return (numerator + half) / denominator;
        return -((-numerator + half) / denominator);
    }

    function _forceCancelMakerQuote(address maker, Side side, uint16 tick) internal {
        _settle(maker, side, tick);

        MakerQuote storage q = quotes[maker][side][tick];
        if (q.shares == 0) return;

        TickPool storage p = pools[side][tick];
        if (q.generation != p.generation) revert StaleQuote();

        uint128 shares = q.shares;
        uint96 removedLots =
            _redeemableLots(shares, p.remainingLots, p.totalShares);

        p.totalShares -= shares;
        p.remainingLots -= removedLots;

        _shrinkRisk(maker, side, removedLots);
        _refreshReservedMargin(maker);
        totalRemovedLots += removedLots;

        delete quotes[maker][side][tick];
        delete quoteFundingCheckpointX96[maker][side][tick];
        activeQuoteCount[maker] -= 1;

        if (p.totalShares == 0) {
            if (p.remainingLots != 0) revert InvalidShareAmount();
            _setOccupied(side, tick, false);
            delete poolRiskCeilingTick[side][tick];
            unchecked {
                ++p.generation;
            }
        }

        emit LiquidityRemoved(maker, side, tick, removedLots, shares, p.generation);
    }

    function _conditionalActive(ConditionalOrder storage order) internal view returns (bool) {
        return (order.flags & 1) != 0;
    }

    function _cancelConditional(uint64 orderId, bool releaseRisk) internal {
        ConditionalOrder storage order = conditionalOrders[orderId];
        if (order.owner == address(0)) revert ConditionalOrderNotFound();
        if (!_conditionalActive(order)) return;

        order.flags &= ~uint8(1);
        activeConditionalCount[order.owner] -= 1;

        bool reduceOnly = (order.flags & 4) != 0;
        if (releaseRisk && !reduceOnly) {
            _shrinkRisk(order.owner, order.side, order.lots);
            _refreshReservedMargin(order.owner);
        }

        uint64 sibling = order.sibling;
        if (sibling != 0) {
            ConditionalOrder storage other = conditionalOrders[sibling];
            if (other.owner != address(0) && other.sibling == orderId) {
                other.sibling = 0;
            }
            order.sibling = 0;
        }

        emit ConditionalOrderCancelled(orderId);
    }

    function _positionAmount(uint96 lots) internal pure returns (int80 amount) {
        if (lots > uint96(uint80(type(int80).max))) revert PositionOverflow();
        amount = int80(uint80(lots));
    }

    function _reduceOnlyLots(address account, Side side, uint96 requested)
        internal
        view
        returns (uint96)
    {
        int80 position = accountRisk[account].settledPosition;
        if (side == Side.Bid) {
            if (position >= 0) return 0;
            uint128 shortReducible = uint80(-position);
            return requested < shortReducible ? requested : uint96(shortReducible);
        }

        if (position <= 0) return 0;
        uint128 longReducible = uint80(position);
        return requested < longReducible ? requested : uint96(longReducible);
    }

    function _applyImmediateTakerFill(
        address account,
        Side side,
        uint96 filledLots,
        uint256 notional,
        bool preReserved
    ) internal {
        _settleExistingPositionFunding(account);

        AccountRisk storage a = accountRisk[account];
        int80 amount = _positionAmount(filledLots);

        if (side == Side.Bid) {
            a.settledPosition += amount;
            a.minPosition += amount;
            if (!preReserved) a.maxPosition += amount;
            tradeCashflow[account] -= int256(notional);
        } else {
            a.settledPosition -= amount;
            a.maxPosition -= amount;
            if (!preReserved) a.minPosition -= amount;
            tradeCashflow[account] += int256(notional);
        }

        _refreshReservedMargin(account);
    }

    function _applyMakerFill(address maker, Side side, uint16 tick, uint96 filledLots) internal {
        if (filledLots == 0) return;

        AccountRisk storage a = accountRisk[maker];
        int80 amount = _positionAmount(filledLots);
        int256 notional = int256(uint256(filledLots) * uint256(tick));

        if (side == Side.Bid) {
            a.settledPosition += amount;
            a.minPosition += amount;
            tradeCashflow[maker] -= notional;
        } else {
            a.settledPosition -= amount;
            a.maxPosition -= amount;
            tradeCashflow[maker] += notional;
        }
    }

    function _refreshReservedMargin(address maker) internal {
        RiskConfig memory r = riskConfig;
        if (!r.enabled) return;

        AccountRisk memory a = accountRisk[maker];
        uint256 absMin = a.minPosition < 0 ? uint256(uint80(-a.minPosition)) : uint256(uint80(a.minPosition));
        uint256 absMax = a.maxPosition < 0 ? uint256(uint80(-a.maxPosition)) : uint256(uint80(a.maxPosition));
        uint256 worstLots = absMin > absMax ? absMin : absMax;

        uint256 worstPrice = accountRiskCeilingTick[maker];
        if (worstPrice == 0) {
            worstPrice = uint256(_currentMarkTick()) + uint256(r.executionBandTicks);
        }
        uint256 required = worstLots * worstPrice * uint256(r.initialMarginBps) / 10_000;

        uint256 previous = reservedMargin[maker];
        if (required > collateralBalance[maker] && required > previous) {
            revert InsufficientCollateral();
        }
        reservedMargin[maker] = required;
    }

    function _bestExecutableTick(Side side) internal view returns (bool ok, uint16 tick) {
        RiskConfig memory r = riskConfig;
        if (!r.enabled) return _bestTick(side);

        uint16 mark = _currentMarkTick();
        uint256 lowerRaw =
            uint256(mark) > uint256(r.executionBandTicks)
                ? uint256(mark) - uint256(r.executionBandTicks)
                : 0;
        uint256 upperRaw = uint256(mark) + uint256(r.executionBandTicks);
        if (upperRaw > type(uint16).max) upperRaw = type(uint16).max;

        uint16 lower = uint16(lowerRaw);
        uint16 upper = uint16(upperRaw);

        (ok, tick) = _bestTick(side);
        while (ok) {
            if (tick >= lower && tick <= upper) {
                uint16 ceiling = poolRiskCeilingTick[side][tick];
                if (ceiling == 0 || mark <= ceiling) return (true, tick);
            }

            if (side == Side.Ask) {
                if (tick > upper) return (false, 0);
            } else {
                if (tick < lower) return (false, 0);
            }

            (ok, tick) = _nextTick(side, tick);
        }
    }

    function _currentMarkTick() internal view returns (uint16) {
        IMarkOracle oracle = markOracle;
        return address(oracle) == address(0) ? riskConfig.markTick : oracle.markTick();
    }

    function _expandRisk(address maker, Side side, uint96 lots) internal {
        AccountRisk storage a = accountRisk[maker];
        int80 amount = _positionAmount(lots);
        if (side == Side.Bid) {
            a.maxPosition += amount;
        } else {
            a.minPosition -= amount;
        }
    }

    function _shrinkRisk(address maker, Side side, uint96 lots) internal {
        AccountRisk storage a = accountRisk[maker];
        int80 amount = _positionAmount(lots);
        if (side == Side.Bid) {
            a.maxPosition -= amount;
        } else {
            a.minPosition += amount;
        }
    }

    function _assertPostOnly(Side side, uint16 tick) internal view {
        if (side == Side.Bid) {
            (bool ok, uint16 ask) = _bestTick(Side.Ask);
            if (ok && tick >= ask) revert CrossesBook();
        } else {
            (bool ok, uint16 bid) = _bestTick(Side.Bid);
            if (ok && tick <= bid) revert CrossesBook();
        }
    }

    function _withinLimit(Side makerSide, uint16 makerTick, uint16 limitTick)
        internal
        pure
        returns (bool)
    {
        return makerSide == Side.Ask ? makerTick <= limitTick : makerTick >= limitTick;
    }

    function _availableThrough(Side makerSide, uint16 limitTick, uint96 stopAt)
        internal
        view
        returns (uint256 available)
    {
        (bool ok, uint16 tick) = _bestExecutableTick(makerSide);
        while (ok && _withinLimit(makerSide, tick, limitTick)) {
            available += pools[makerSide][tick].remainingLots;
            if (available >= stopAt) return available;
            (ok, tick) = _nextTick(makerSide, tick);
        }
    }

    function _setOccupied(Side side, uint16 tick, bool occupied) internal {
        uint8 wordIndex = uint8(tick >> 8);
        uint8 bitIndex = uint8(tick);
        uint256 bit = uint256(1) << bitIndex;
        uint256 word = _tickWords[side][wordIndex];

        if (occupied) {
            uint256 next = word | bit;
            _tickWords[side][wordIndex] = next;
            if (word == 0) _occupiedWords[side] |= uint256(1) << wordIndex;
        } else {
            uint256 next = word & ~bit;
            _tickWords[side][wordIndex] = next;
            if (next == 0) _occupiedWords[side] &= ~(uint256(1) << wordIndex);
        }
    }

    function _bestTick(Side side) internal view returns (bool ok, uint16 tick) {
        uint256 words = _occupiedWords[side];
        if (words == 0) return (false, 0);

        uint8 wordIndex;
        uint8 bitIndex;
        if (side == Side.Ask) {
            wordIndex = _lsb(words);
            bitIndex = _lsb(_tickWords[side][wordIndex]);
        } else {
            wordIndex = _msb(words);
            bitIndex = _msb(_tickWords[side][wordIndex]);
        }

        tick = (uint16(wordIndex) << 8) | uint16(bitIndex);
        ok = true;
    }

    function _nextTick(Side side, uint16 current) internal view returns (bool ok, uint16 tick) {
        uint8 wi = uint8(current >> 8);
        uint8 bi = uint8(current);

        if (side == Side.Ask) {
            if (bi != type(uint8).max) {
                uint256 sameWord =
                    _tickWords[side][wi] & (type(uint256).max << (uint256(bi) + 1));
                if (sameWord != 0) {
                    return (true, (uint16(wi) << 8) | uint16(_lsb(sameWord)));
                }
            }
            if (wi == type(uint8).max) return (false, 0);
            uint256 higherWords =
                _occupiedWords[side] & (type(uint256).max << (uint256(wi) + 1));
            if (higherWords == 0) return (false, 0);
            uint8 higherWordIndex = _lsb(higherWords);
            return (
                true,
                (uint16(higherWordIndex) << 8)
                    | uint16(_lsb(_tickWords[side][higherWordIndex]))
            );
        }

        if (bi != 0) {
            uint256 sameWord = _tickWords[side][wi] & ((uint256(1) << bi) - 1);
            if (sameWord != 0) {
                return (true, (uint16(wi) << 8) | uint16(_msb(sameWord)));
            }
        }
        if (wi == 0) return (false, 0);
        uint256 lowerWords = _occupiedWords[side] & ((uint256(1) << wi) - 1);
        if (lowerWords == 0) return (false, 0);
        uint8 lowerWordIndex = _msb(lowerWords);
        return (
            true,
            (uint16(lowerWordIndex) << 8) | uint16(_msb(_tickWords[side][lowerWordIndex]))
        );
    }

    function _lsb(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert InsufficientLiquidity();
        if (x & type(uint128).max == 0) {
            x >>= 128;
            r += 128;
        }
        if (x & type(uint64).max == 0) {
            x >>= 64;
            r += 64;
        }
        if (x & type(uint32).max == 0) {
            x >>= 32;
            r += 32;
        }
        if (x & type(uint16).max == 0) {
            x >>= 16;
            r += 16;
        }
        if (x & type(uint8).max == 0) {
            x >>= 8;
            r += 8;
        }
        if (x & 0x0f == 0) {
            x >>= 4;
            r += 4;
        }
        if (x & 0x03 == 0) {
            x >>= 2;
            r += 2;
        }
        if (x & 0x01 == 0) r += 1;
    }

    function _msb(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert InsufficientLiquidity();
        if (x >> 128 != 0) {
            x >>= 128;
            r += 128;
        }
        if (x >> 64 != 0) {
            x >>= 64;
            r += 64;
        }
        if (x >> 32 != 0) {
            x >>= 32;
            r += 32;
        }
        if (x >> 16 != 0) {
            x >>= 16;
            r += 16;
        }
        if (x >> 8 != 0) {
            x >>= 8;
            r += 8;
        }
        if (x >> 4 != 0) {
            x >>= 4;
            r += 4;
        }
        if (x >> 2 != 0) {
            x >>= 2;
            r += 2;
        }
        if (x >> 1 != 0) r += 1;
    }
}

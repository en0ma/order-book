// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {IMarkOracle} from "../interfaces/IMarkOracle.sol";
import {IOrderBookCore} from "./IOrderBookCore.sol";
import {OrderBookMath} from "./OrderBookMath.sol";

/// @title OrderBookCore
/// @notice Deployable hot-path CLOB/risk/funding core.
/// @dev Advanced order state lives in a separate module set once after deployment.
contract OrderBookCore is IOrderBookCore {
    using OrderBookMath for Side;
    uint256 public constant INITIAL_SHARE_SCALE = 1_000_000;
    uint256 public constant ACCUMULATOR_SCALE = 1 << 96;
    int256 public constant FUNDING_SCALE = 1e18;

    struct TickPool {
        uint128 totalShares;
        uint96 remainingLots;
        uint32 generation;
    }

    struct MakerQuote {
        uint128 shares;
        uint96 claimLots;
        uint32 generation;
    }

    struct AccountRisk {
        int80 settledPosition;
        int80 minPosition;
        int80 maxPosition;
    }

    struct AccountMeta {
        int128 fundingCheckpointX18;
        uint32 activeQuoteCount;
        uint16 riskCeilingTick;
    }

    struct RiskConfig {
        uint16 markTick;
        uint16 executionBandTicks;
        uint16 initialMarginBps;
        bool enabled;
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
    error ModuleAlreadyConfigured();
    error ModuleNotConfigured();
    error ReduceOnlyViolation();
    error PositionOverflow();
    error MinimumFillNotMet();

    address public immutable owner;
    address public advancedModule;

    IERC20Minimal public collateralToken;
    IMarkOracle public markOracle;
    RiskConfig public riskConfig;

    mapping(Side => mapping(uint16 => TickPool)) public pools;
    mapping(address => mapping(Side => mapping(uint16 => MakerQuote))) public quotes;
    mapping(address => AccountRisk) public accountRisk;
    mapping(address => AccountMeta) internal _accountMeta;
    mapping(address => mapping(Side => mapping(uint16 => uint128))) public moduleLockedShares;

    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public reservedMargin;
    mapping(address => int256) public fundingCashflow;
    mapping(address => int256) public tradeCashflow;

    int128 public fundingIndexX18;
    mapping(Side => mapping(uint16 => int256)) public fundingEntryPerShareX96;
    mapping(Side => mapping(uint16 => mapping(uint32 => int256)))
        public closedFundingEntryPerShareX96;
    mapping(Side => mapping(uint16 => mapping(uint32 => uint128)))
        public closedFundingOutstandingShares;
    mapping(address => mapping(Side => mapping(uint16 => int256)))
        public quoteFundingCheckpointX96;

    mapping(Side => mapping(uint16 => uint16)) public poolRiskCeilingTick;

    mapping(Side => mapping(uint8 => uint256)) internal _tickWords;
    mapping(Side => uint256) internal _occupiedWords;

    event AdvancedModuleConfigured(address indexed module);
    event SettlementConfigured(address indexed collateralToken, address indexed markOracle);
    event RiskConfigured(uint16 markTick, uint16 executionBandTicks, uint16 initialMarginBps);
    event FundingIndexUpdated(int128 fundingIndexX18);
    event CollateralCredited(address indexed account, uint256 amount);
    event CollateralDebited(address indexed account, uint256 amount);
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
    event Trade(address indexed taker, Side indexed takerSide, uint16 indexed tick, uint96 lots);
    event FundingSettled(address indexed account, int256 cashflowDelta);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyModule() {
        if (msg.sender != advancedModule || msg.sender == address(0)) revert Unauthorized();
        _;
    }

    function configureAdvancedModule(address module) external onlyOwner {
        if (module == address(0)) revert ModuleNotConfigured();
        if (advancedModule != address(0)) revert ModuleAlreadyConfigured();
        advancedModule = module;
        emit AdvancedModuleConfigured(module);
    }

    function configureSettlement(address token, address oracle) external onlyOwner {
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
        onlyOwner
    {
        if (initialMarginBps == 0 || initialMarginBps > 10_000) revert InvalidRiskConfig();

        riskConfig = RiskConfig({
            markTick: markTick,
            executionBandTicks: executionBandTicks,
            initialMarginBps: initialMarginBps,
            enabled: true
        });

        emit RiskConfigured(markTick, executionBandTicks, initialMarginBps);
    }

    function setFundingIndex(int128 nextFundingIndexX18) external onlyOwner {
        fundingIndexX18 = nextFundingIndexX18;
        emit FundingIndexUpdated(nextFundingIndexX18);
    }

    function setMarkTick(uint16 markTick) external onlyOwner {
        if (!riskConfig.enabled || address(markOracle) != address(0)) revert InvalidRiskConfig();
        riskConfig.markTick = markTick;
    }

    function currentMarkTick() public view override returns (uint16) {
        IMarkOracle oracle = markOracle;
        return address(oracle) == address(0) ? riskConfig.markTick : oracle.markTick();
    }

    function accountPosition(address account) external view override returns (int80) {
        return accountRisk[account].settledPosition;
    }

    function poolState(Side side, uint16 tick)
        external
        view
        override
        returns (uint128 totalShares, uint96 remainingLots, uint32 generation)
    {
        TickPool memory p = pools[side][tick];
        return (p.totalShares, p.remainingLots, p.generation);
    }

    function quoteStateRaw(address account, Side side, uint16 tick)
        external
        view
        override
        returns (uint128 shares, uint96 claimLots, uint32 generation)
    {
        MakerQuote memory q = quotes[account][side][tick];
        return (q.shares, q.claimLots, q.generation);
    }

    function activeQuoteCount(address account) external view override returns (uint32) {
        return _accountMeta[account].activeQuoteCount;
    }

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
        if (_accountMeta[msg.sender].activeQuoteCount != 0) revert InsufficientCollateral();

        _settleExistingPositionFunding(msg.sender);

        uint256 balance = collateralBalance[msg.sender];
        if (amount > balance) revert InsufficientCollateral();

        int256 equityAfter = accountEquity(msg.sender) - int256(amount);
        if (equityAfter < int256(reservedMargin[msg.sender])) revert InsufficientCollateral();

        collateralBalance[msg.sender] = balance - amount;

        IERC20Minimal token = collateralToken;
        if (address(token) != address(0)) {
            if (!token.transfer(msg.sender, amount)) revert TokenTransferFailed();
        }

        emit CollateralDebited(msg.sender, amount);
    }

    function addLiquidity(Side side, uint16 tick, uint96 lots)
        external
        returns (uint128 mintedShares)
    {
        mintedShares = _addLiquidityFor(msg.sender, side, tick, lots, false, 0, true);
    }

    function removeShares(Side side, uint16 tick, uint128 sharesToBurn)
        external
        returns (uint96 removedLots)
    {
        MakerQuote memory q = quotes[msg.sender][side][tick];
        uint128 locked = moduleLockedShares[msg.sender][side][tick];
        if (sharesToBurn > q.shares - locked) revert InvalidShareAmount();

        removedLots = _removeSharesFor(msg.sender, side, tick, sharesToBurn);
    }

    function settle(Side side, uint16 tick) external returns (uint96 filledLots) {
        filledLots = _settle(msg.sender, side, tick);
        _settleExistingPositionFunding(msg.sender);
    }

    function take(Side side, uint16 limitTick, uint96 lots, FillPolicy policy)
        external
        returns (uint96 filledLots)
    {
        filledLots = _takeFor(msg.sender, side, limitTick, lots, policy, false, false);
    }

    function takeReduceOnly(Side side, uint16 limitTick, uint96 lots, FillPolicy policy)
        external
        returns (uint96 filledLots)
    {
        if (_accountMeta[msg.sender].activeQuoteCount != 0) revert ReduceOnlyViolation();
        filledLots = _takeFor(msg.sender, side, limitTick, lots, policy, true, false);
    }

    function takeMinFill(Side side, uint16 limitTick, uint96 lots, uint96 minFillLots)
        external
        returns (uint96 filledLots)
    {
        if (minFillLots == 0 || minFillLots > lots) revert InvalidShareAmount();

        Side makerSide = side.opposite();
        if (_availableThrough(makerSide, limitTick, minFillLots) < minFillLots) {
            revert MinimumFillNotMet();
        }

        filledLots = _takeFor(msg.sender, side, limitTick, lots, FillPolicy.IOC, false, false);
        if (filledLots < minFillLots) revert MinimumFillNotMet();
    }

    function moduleReserveExposure(address account, Side side, uint96 lots)
        external
        override
        onlyModule
        returns (uint16 riskCeilingTick)
    {
        if (lots == 0) revert ZeroAmount();

        _expandRisk(account, side, lots);

        if (riskConfig.enabled) {
            riskCeilingTick =
                OrderBookMath.upperTick(currentMarkTick(), riskConfig.executionBandTicks);

            if (riskCeilingTick > _accountMeta[account].riskCeilingTick) {
                _accountMeta[account].riskCeilingTick = riskCeilingTick;
            }
        }

        _refreshReservedMargin(account);
    }

    function moduleReleaseExposure(address account, Side side, uint96 lots)
        external
        override
        onlyModule
    {
        if (lots == 0) return;
        _shrinkRisk(account, side, lots);
        _refreshReservedMargin(account);
    }

    function moduleTake(
        address account,
        Side side,
        uint16 limitTick,
        uint96 lots,
        FillPolicy policy,
        bool reduceOnly,
        bool preReserved
    ) external override onlyModule returns (uint96 filledLots) {
        if (reduceOnly && _accountMeta[account].activeQuoteCount != 0) {
            revert ReduceOnlyViolation();
        }
        filledLots =
            _takeFor(account, side, limitTick, lots, policy, reduceOnly, preReserved);
    }

    function moduleAddLiquidity(
        address account,
        Side side,
        uint16 tick,
        uint96 lots,
        uint16 reservedRiskCeiling
    ) external override onlyModule returns (uint128 mintedShares) {
        mintedShares =
            _addLiquidityFor(account, side, tick, lots, true, reservedRiskCeiling, true);
        moduleLockedShares[account][side][tick] += mintedShares;
    }

    function moduleSettle(address account, Side side, uint16 tick)
        external
        override
        onlyModule
        returns (uint96 filledLots)
    {
        filledLots = _settle(account, side, tick);
        _settleExistingPositionFunding(account);
    }

    function moduleRemoveLockedShares(
        address account,
        Side side,
        uint16 tick,
        uint128 shares
    ) external override onlyModule returns (uint96 removedLots) {
        uint128 locked = moduleLockedShares[account][side][tick];
        if (shares == 0 || shares > locked) revert InvalidShareAmount();

        moduleLockedShares[account][side][tick] = locked - shares;
        removedLots = _removeSharesFor(account, side, tick, shares);
    }

    function moduleUnlockShares(address account, Side side, uint16 tick, uint128 shares)
        external
        override
        onlyModule
    {
        uint128 locked = moduleLockedShares[account][side][tick];
        if (shares > locked) revert InvalidShareAmount();
        moduleLockedShares[account][side][tick] = locked - shares;
    }

    function moduleForceCancelQuote(address account, Side side, uint16 tick)
        external
        override
        onlyModule
        returns (uint96 removedLots)
    {
        _settle(account, side, tick);

        MakerQuote storage q = quotes[account][side][tick];
        if (q.shares == 0) return 0;

        TickPool storage p = pools[side][tick];
        if (q.generation != p.generation) revert StaleQuote();

        removedLots =
            OrderBookMath.redeemableLots(q.shares, p.remainingLots, p.totalShares);

        uint128 shares = q.shares;
        p.totalShares -= shares;
        p.remainingLots -= removedLots;

        _shrinkRisk(account, side, removedLots);
        _refreshReservedMargin(account);


        delete quotes[account][side][tick];
        delete quoteFundingCheckpointX96[account][side][tick];
        delete moduleLockedShares[account][side][tick];
        _accountMeta[account].activeQuoteCount -= 1;

        if (p.totalShares == 0) {
            if (p.remainingLots != 0) revert InvalidShareAmount();
            _setOccupied(side, tick, false);
            delete poolRiskCeilingTick[side][tick];
            unchecked {
                ++p.generation;
            }
        }

        emit LiquidityRemoved(account, side, tick, removedLots, shares, p.generation);
    }

    function accountEquity(address account) public view override returns (int256 equity) {
        AccountRisk memory a = accountRisk[account];

        int256 pendingFunding =
            -(int256(a.settledPosition)
                * (int256(fundingIndexX18)
                    - int256(_accountMeta[account].fundingCheckpointX18))
                / FUNDING_SCALE);

        equity = int256(collateralBalance[account]) + tradeCashflow[account]
            + fundingCashflow[account] + pendingFunding
            + int256(a.settledPosition) * int256(uint256(currentMarkTick()));
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

        Side makerSide = takerSide.opposite();

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
            if (!ok || !OrderBookMath.withinLimit(makerSide, tick, limitTick)) break;

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
        bool wasEmpty = p.remainingLots == 0;

        _preparePoolRiskCeiling(
            maker, side, tick, wasEmpty, preReserved, reservedRiskCeiling
        );

        mintedShares = _mintPoolShares(p, lots);
        _creditMakerQuote(maker, side, tick, p.generation, mintedShares, lots);

        if (!preReserved) {
            _expandRisk(maker, side, lots);
            _refreshReservedMargin(maker);
        }

        if (wasEmpty) _setOccupied(side, tick, true);

        emit LiquidityAdded(maker, side, tick, lots, mintedShares, p.generation);
    }

    function _removeSharesFor(
        address maker,
        Side side,
        uint16 tick,
        uint128 sharesToBurn
    ) internal returns (uint96 removedLots) {
        if (sharesToBurn == 0) revert ZeroAmount();

        _settle(maker, side, tick);

        TickPool storage p = pools[side][tick];
        MakerQuote storage q = quotes[maker][side][tick];

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

        _shrinkRisk(maker, side, removedLots);
        _refreshReservedMargin(maker);

        if (q.shares == 0) {
            delete quotes[maker][side][tick];
            delete quoteFundingCheckpointX96[maker][side][tick];
            _accountMeta[maker].activeQuoteCount -= 1;
        }

        if (p.totalShares == 0) {
            if (p.remainingLots != 0) revert InvalidShareAmount();
            _setOccupied(side, tick, false);
            delete poolRiskCeilingTick[side][tick];

            unchecked {
                ++p.generation;
            }
        }

        emit LiquidityRemoved(maker, side, tick, removedLots, sharesToBurn, p.generation);
    }

    function _preparePoolRiskCeiling(
        address maker,
        Side side,
        uint16 tick,
        bool wasEmpty,
        bool preReserved,
        uint16 reservedRiskCeiling
    ) internal {
        if (!riskConfig.enabled) return;

        uint16 mark = currentMarkTick();
        uint16 riskCeiling;

        if (wasEmpty) {
            if (preReserved) {
                if (reservedRiskCeiling == 0 || mark > reservedRiskCeiling) {
                    revert InvalidRiskConfig();
                }
                riskCeiling = reservedRiskCeiling;
            } else {
                riskCeiling =
                    OrderBookMath.upperTick(mark, riskConfig.executionBandTicks);
            }
            poolRiskCeilingTick[side][tick] = riskCeiling;
        } else {
            riskCeiling = poolRiskCeilingTick[side][tick];
            if (mark > riskCeiling) revert InvalidRiskConfig();
            if (preReserved && riskCeiling > reservedRiskCeiling) {
                revert InvalidRiskConfig();
            }
        }

        if (riskCeiling > _accountMeta[maker].riskCeilingTick) {
            _accountMeta[maker].riskCeilingTick = riskCeiling;
        }
    }

    function _mintPoolShares(TickPool storage p, uint96 lots)
        internal
        returns (uint128 mintedShares)
    {
        if (p.totalShares == 0) {
            uint256 rawInitial = uint256(lots) * INITIAL_SHARE_SCALE;
            if (rawInitial > type(uint128).max) revert Overflow();
            mintedShares = uint128(rawInitial);
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
    }

    function _creditMakerQuote(
        address maker,
        Side side,
        uint16 tick,
        uint32 generation,
        uint128 mintedShares,
        uint96 lots
    ) internal {
        MakerQuote storage q = quotes[maker][side][tick];
        bool isNewQuote = q.shares == 0;

        if (isNewQuote) {
            q.generation = generation;
            quoteFundingCheckpointX96[maker][side][tick] =
                fundingEntryPerShareX96[side][tick];
        } else if (q.generation != generation) {
            revert StaleQuote();
        }

        q.shares += mintedShares;
        q.claimLots += lots;

        if (isNewQuote) _accountMeta[maker].activeQuoteCount += 1;
    }

    function _settle(address maker, Side side, uint16 tick)
        internal
        returns (uint96 filledLots)
    {
        MakerQuote storage q = quotes[maker][side][tick];
        if (q.shares == 0) return 0;

        TickPool storage p = pools[side][tick];

        if (q.generation != p.generation) {
            filledLots = q.claimLots;
            uint32 oldGeneration = q.generation;

            int256 finalFundingEntry =
                closedFundingEntryPerShareX96[side][tick][oldGeneration];

            _settleFundingForQuote(
                maker, side, tick, q.shares, filledLots, finalFundingEntry
            );
            _applyMakerFill(maker, side, tick, filledLots);
            _refreshReservedMargin(maker);

            uint128 outstanding =
                closedFundingOutstandingShares[side][tick][oldGeneration];

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
            _accountMeta[maker].activeQuoteCount -= 1;

            emit MakerSettled(maker, side, tick, filledLots, oldGeneration);
            return filledLots;
        }

        uint96 currentClaim =
            OrderBookMath.redeemableLots(q.shares, p.remainingLots, p.totalShares);

        if (currentClaim >= q.claimLots) {
            q.claimLots = currentClaim;
            return 0;
        }

        filledLots = q.claimLots - currentClaim;
        q.claimLots = currentClaim;

        int256 currentFundingEntry = fundingEntryPerShareX96[side][tick];

        _settleFundingForQuote(
            maker, side, tick, q.shares, filledLots, currentFundingEntry
        );
        quoteFundingCheckpointX96[maker][side][tick] = currentFundingEntry;

        _applyMakerFill(maker, side, tick, filledLots);
        _refreshReservedMargin(maker);

        emit MakerSettled(maker, side, tick, filledLots, q.generation);
    }

    function _recordFundingEntry(
        Side side,
        uint16 tick,
        uint128 totalShares,
        uint96 fillLots
    ) internal {
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

        int256 deltaPerShare =
            finalFundingEntryPerShareX96 - quoteFundingCheckpointX96[maker][side][tick];

        int256 weightedEntry =
            _divNearestSigned(
                int256(uint256(shares)) * deltaPerShare,
                int256(ACCUMULATOR_SCALE)
            );

        int256 signedLots =
            side == Side.Bid ? int256(uint256(filledLots)) : -int256(uint256(filledLots));

        int256 currentFunding =
            signedLots * int256(fundingIndexX18) / FUNDING_SCALE;

        int256 entryFunding =
            signedLots == 0 ? int256(0) : (signedLots > 0 ? weightedEntry : -weightedEntry);

        int256 cashflowDelta = entryFunding - currentFunding;

        if (cashflowDelta != 0) {
            fundingCashflow[maker] += cashflowDelta;
            emit FundingSettled(maker, cashflowDelta);
        }

        _accountMeta[maker].fundingCheckpointX18 = fundingIndexX18;
    }

    function _settleExistingPositionFunding(address account) internal {
        int128 currentIndex = fundingIndexX18;
        int128 checkpoint = _accountMeta[account].fundingCheckpointX18;

        if (currentIndex == checkpoint) return;

        int256 position = int256(accountRisk[account].settledPosition);
        int256 deltaIndex = int256(currentIndex) - int256(checkpoint);

        if (position != 0) {
            int256 cashflowDelta = -(position * deltaIndex / FUNDING_SCALE);
            fundingCashflow[account] += cashflowDelta;
            emit FundingSettled(account, cashflowDelta);
        }

        _accountMeta[account].fundingCheckpointX18 = currentIndex;
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

    function _applyMakerFill(address maker, Side side, uint16 tick, uint96 filledLots)
        internal
    {
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

    function _expandRisk(address account, Side side, uint96 lots) internal {
        AccountRisk storage a = accountRisk[account];
        int80 amount = _positionAmount(lots);

        if (side == Side.Bid) {
            a.maxPosition += amount;
        } else {
            a.minPosition -= amount;
        }
    }

    function _shrinkRisk(address account, Side side, uint96 lots) internal {
        AccountRisk storage a = accountRisk[account];
        int80 amount = _positionAmount(lots);

        if (side == Side.Bid) {
            a.maxPosition -= amount;
        } else {
            a.minPosition += amount;
        }
    }

    function _refreshReservedMargin(address account) internal {
        if (!riskConfig.enabled) return;

        AccountRisk memory a = accountRisk[account];

        uint256 absMin = uint256(OrderBookMath.absPosition(a.minPosition));
        uint256 absMax = uint256(OrderBookMath.absPosition(a.maxPosition));

        uint256 worstLots = absMin > absMax ? absMin : absMax;

        uint256 worstPrice = _accountMeta[account].riskCeilingTick;
        if (worstPrice == 0) {
            worstPrice =
                uint256(currentMarkTick()) + uint256(riskConfig.executionBandTicks);
        }

        uint256 required =
            worstLots * worstPrice * uint256(riskConfig.initialMarginBps) / 10_000;

        uint256 previous = reservedMargin[account];

        if (required > collateralBalance[account] && required > previous) {
            revert InsufficientCollateral();
        }

        if (required != previous) reservedMargin[account] = required;
    }

    function _reduceOnlyLots(address account, Side side, uint96 requested)
        internal
        view
        returns (uint96)
    {
        int80 position = accountRisk[account].settledPosition;

        if (side == Side.Bid) {
            if (position >= 0) return 0;
            uint80 shortReducible = uint80(-position);
            return requested < shortReducible ? requested : uint96(shortReducible);
        }

        if (position <= 0) return 0;
        uint80 longReducible = uint80(position);
        return requested < longReducible ? requested : uint96(longReducible);
    }

    function _positionAmount(uint96 lots) internal pure returns (int80 amount) {
        if (lots > uint96(uint80(type(int80).max))) revert PositionOverflow();
        amount = int80(uint80(lots));
    }

    function _availableThrough(Side makerSide, uint16 limitTick, uint96 stopAt)
        internal
        view
        returns (uint256 available)
    {
        (bool ok, uint16 tick) = _bestExecutableTick(makerSide);

        while (ok && OrderBookMath.withinLimit(makerSide, tick, limitTick)) {
            available += pools[makerSide][tick].remainingLots;
            if (available >= stopAt) return available;
            (ok, tick) = _nextTick(makerSide, tick);
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

    function _bestExecutableTick(Side side) internal view returns (bool ok, uint16 tick) {
        RiskConfig memory r = riskConfig;
        if (!r.enabled) return _bestTick(side);

        uint16 mark = currentMarkTick();
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

    function _nextTick(Side side, uint16 current)
        internal
        view
        returns (bool ok, uint16 tick)
    {
        uint8 wi = uint8(current >> 8);
        uint8 bi = uint8(current);

        if (side == Side.Ask) {
            if (bi != type(uint8).max) {
                uint256 sameWord =
                    _tickWords[side][wi]
                        & (type(uint256).max << (uint256(bi) + 1));

                if (sameWord != 0) {
                    return (true, (uint16(wi) << 8) | uint16(_lsb(sameWord)));
                }
            }

            if (wi == type(uint8).max) return (false, 0);

            uint256 higherWords =
                _occupiedWords[side]
                    & (type(uint256).max << (uint256(wi) + 1));

            if (higherWords == 0) return (false, 0);

            uint8 higherWordIndex = _lsb(higherWords);

            return (
                true,
                (uint16(higherWordIndex) << 8)
                    | uint16(_lsb(_tickWords[side][higherWordIndex]))
            );
        }

        if (bi != 0) {
            uint256 sameWord =
                _tickWords[side][wi] & ((uint256(1) << bi) - 1);

            if (sameWord != 0) {
                return (true, (uint16(wi) << 8) | uint16(_msb(sameWord)));
            }
        }

        if (wi == 0) return (false, 0);

        uint256 lowerWords =
            _occupiedWords[side] & ((uint256(1) << wi) - 1);

        if (lowerWords == 0) return (false, 0);

        uint8 lowerWordIndex = _msb(lowerWords);

        return (
            true,
            (uint16(lowerWordIndex) << 8)
                | uint16(_msb(_tickWords[side][lowerWordIndex]))
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

    function _divNearestSigned(int256 numerator, int256 denominator)
        internal
        pure
        returns (int256)
    {
        int256 half = denominator / 2;
        if (numerator >= 0) return (numerator + half) / denominator;
        return -((-numerator + half) / denominator);
    }
}

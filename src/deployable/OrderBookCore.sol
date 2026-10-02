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
    uint256 internal constant INITIAL_SHARE_SCALE = 1_000_000;
    uint256 internal constant ACCUMULATOR_SCALE = 1 << 96;
    int256 internal constant FUNDING_SCALE = 1e18;

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

    struct ModuleLock {
        uint128 shares;
        uint32 generation;
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
    error ModuleAlreadyConfigured();
    error ModuleNotConfigured();
    error ReduceOnlyViolation();
    error PositionOverflow();

    address internal immutable owner;
    address public fundingUpdater;
    address public advancedModule;
    address public override portfolioController;

    IERC20Minimal internal immutable collateralToken;
    IMarkOracle public immutable markOracle;
    uint16 internal immutable executionBandTicks;
    uint16 internal immutable initialMarginBps;
    uint128 internal collateralUnitsPerLotTick;
    bool internal unitScaleLocked;

    mapping(Side => mapping(uint16 => TickPool)) public pools;
    mapping(address => mapping(Side => mapping(uint16 => MakerQuote))) public quotes;
    mapping(address => AccountRisk) public accountRisk;
    mapping(address => AccountMeta) internal _accountMeta;
    mapping(address => mapping(Side => mapping(uint16 => ModuleLock))) internal moduleLocks;

    mapping(address => uint256) internal collateralBalance;
    uint256 internal totalLocalCollateral;
    mapping(address => uint256) internal reservedMargin;
    mapping(address => int256) internal fundingCashflow;
    mapping(address => int256) internal tradeCashflow;

    int128 internal fundingIndexX18;
    uint32 internal immutable feeSchedulePacked;
    uint256 internal _feeAccountingPacked;
    uint256 public insuranceReserves;
    mapping(Side => mapping(uint16 => int256)) internal fundingEntryPerShareX96;
    mapping(Side => mapping(uint16 => mapping(uint32 => int256)))
        internal closedFundingEntryPerShareX96;
    mapping(Side => mapping(uint16 => mapping(uint32 => uint256)))
        internal closedGenerationAccounting;
    // Executed taker lots not yet attributed to makers in each generation.
    mapping(Side => mapping(uint16 => mapping(uint32 => uint96)))
        internal generationMakerFillBudget;
    mapping(Side => mapping(uint16 => uint128)) internal currentMakerRebateReserve;
    mapping(address => mapping(Side => mapping(uint16 => int256)))
        internal quoteFundingCheckpointX96;

    mapping(Side => mapping(uint16 => uint16)) internal poolRiskCeilingTick;

    mapping(Side => mapping(uint8 => uint256)) internal _tickWords;
    mapping(Side => uint256) internal _occupiedWords;

    event AdvancedModuleConfigured(address indexed module);
    event FundingUpdaterChanged(address indexed previousUpdater, address indexed newUpdater);
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
    event InsuranceFunded(address indexed funder, uint256 amount);
    event ProtocolFeesAllocatedToInsurance(uint256 amount);
    event BadDebtCovered(address indexed account, uint256 amount);
    event LiquidationRewardPaid(address indexed liquidator, uint256 amount);
    event AccountingUnitScaleConfigured(uint128 collateralUnitsPerLotTick);

    constructor(
        address collateralToken_,
        address markOracle_,
        uint16 executionBandTicks_,
        uint16 initialMarginBps_,
        uint16 takerFeeBps_,
        uint16 makerRebateBps_
    ) {
        if (
            collateralToken_ == address(0) || markOracle_ == address(0)
                || initialMarginBps_ == 0 || initialMarginBps_ > 10_000
                || takerFeeBps_ > 10_000 || makerRebateBps_ > takerFeeBps_
        ) revert InvalidRiskConfig();

        owner = msg.sender;
        fundingUpdater = msg.sender;
        collateralToken = IERC20Minimal(collateralToken_);
        markOracle = IMarkOracle(markOracle_);
        executionBandTicks = executionBandTicks_;
        initialMarginBps = initialMarginBps_;
        collateralUnitsPerLotTick = 1;
        feeSchedulePacked =
            uint32(takerFeeBps_) | (uint32(makerRebateBps_) << 16);
    }

    modifier onlyOwner() {
        _requireOwner();
        _;
    }

    modifier onlyModule() {
        _requireModule();
        _;
    }

    modifier onlyRiskModule() {
        _requireRiskModule();
        _;
    }

    function _requireOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    function _requireModule() internal view {
        if (msg.sender != advancedModule || msg.sender == address(0)) revert Unauthorized();
    }

    function _requireRiskModule() internal view {
        if (msg.sender != advancedModule && msg.sender != portfolioController) {
            revert Unauthorized();
        }
    }

    function _requireStandalone() internal view {
        if (portfolioController != address(0)) revert Unauthorized();
    }

    function _requirePortfolioControllerIfEnabled() internal view {
        if (
            portfolioController != address(0)
                && msg.sender != portfolioController
        ) revert Unauthorized();
    }

    function configureAdvancedModule(address module) external onlyOwner {
        if (module == address(0)) revert ModuleNotConfigured();
        if (advancedModule != address(0)) revert ModuleAlreadyConfigured();
        advancedModule = module;
        emit AdvancedModuleConfigured(module);
    }

    function configurePortfolioController(address controller) external onlyOwner {
        if (controller == address(0)) revert Unauthorized();
        if (portfolioController != address(0)) revert ModuleAlreadyConfigured();
        if (totalLocalCollateral != 0 || feeSchedulePacked != 0 || insuranceReserves != 0) {
            revert InvalidRiskConfig();
        }

        portfolioController = controller;
    }

    function configureAccountingUnitScale(uint128 collateralUnitsPerLotTick_) external onlyOwner {
        if (unitScaleLocked || collateralUnitsPerLotTick_ == 0) revert InvalidRiskConfig();
        collateralUnitsPerLotTick = collateralUnitsPerLotTick_;
        unitScaleLocked = true;
        emit AccountingUnitScaleConfigured(collateralUnitsPerLotTick_);
    }

    function setFundingUpdater(address nextUpdater) external onlyOwner {
        if (nextUpdater == address(0)) revert Unauthorized();
        address previous = fundingUpdater;
        fundingUpdater = nextUpdater;
        emit FundingUpdaterChanged(previous, nextUpdater);
    }

    function setFundingIndex(int128 nextFundingIndexX18) external {
        if (msg.sender != fundingUpdater) revert Unauthorized();
        fundingIndexX18 = nextFundingIndexX18;
        emit FundingIndexUpdated(nextFundingIndexX18);
    }

    function currentMarkTick() public view override returns (uint16) {
        return markOracle.markTick();
    }

    function activeQuoteCount(address account) external view override returns (uint32) {
        return _accountMeta[account].activeQuoteCount;
    }

    function depositCollateral(uint256 amount) external {
        _pullCollateralExact(amount);

        collateralBalance[msg.sender] += amount;
        totalLocalCollateral += amount;
        emit CollateralCredited(msg.sender, amount);
    }

    function fundInsurance(uint256 amount) external {
        _pullCollateralExact(amount);

        insuranceReserves += amount;
        emit InsuranceFunded(msg.sender, amount);
    }

    function _pullCollateralExact(uint256 amount) internal {
        _requireStandalone();
        if (amount == 0) revert ZeroAmount();
        if (!unitScaleLocked) unitScaleLocked = true;

        IERC20Minimal token = collateralToken;
        uint256 beforeBalance = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount)) {
            revert TokenTransferFailed();
        }
        if (token.balanceOf(address(this)) - beforeBalance != amount) {
            revert UnsupportedTokenBehavior();
        }
    }

    function _transferCollateralOut(address recipient, uint256 amount) internal {
        if (!collateralToken.transfer(recipient, amount)) revert TokenTransferFailed();
    }

    function protocolFeesAccrued() external view returns (uint256) {
        return uint256(uint128(_feeAccountingPacked));
    }

    function allocateProtocolFeesToInsurance(uint256 amount) external onlyOwner {
        uint256 packed = _feeAccountingPacked;
        uint256 accrued = uint256(uint128(packed));
        if (amount == 0 || amount > accrued) revert InsufficientCollateral();

        _feeAccountingPacked =
            (packed & ~uint256(type(uint128).max)) | (accrued - amount);
        insuranceReserves += amount;
        emit ProtocolFeesAllocatedToInsurance(amount);
    }

    function withdrawCollateral(uint256 amount) external {
        _requireStandalone();
        if (amount == 0) revert ZeroAmount();
        if (_accountMeta[msg.sender].activeQuoteCount != 0) revert InsufficientCollateral();

        _settleExistingPositionFunding(msg.sender);

        int256 settledCash =
            int256(collateralBalance[msg.sender]) + tradeCashflow[msg.sender]
                + fundingCashflow[msg.sender];
        if (settledCash < int256(amount)) revert InsufficientCollateral();

        int256 equityAfter = accountEquity(msg.sender) - int256(amount);
        if (equityAfter < int256(reservedMargin[msg.sender])) revert InsufficientCollateral();

        uint256 localBefore = collateralBalance[msg.sender];
        _debitSettledCash(msg.sender, amount);
        uint256 localDebit = amount < localBefore ? amount : localBefore;
        totalLocalCollateral -= localDebit;

        _transferCollateralOut(msg.sender, amount);

        emit CollateralDebited(msg.sender, amount);
    }

    function addLiquidity(Side side, uint16 tick, uint96 lots)
        external
        returns (uint128 mintedShares)
    {
        _requireStandalone();
        mintedShares = _addLiquidityFor(msg.sender, side, tick, lots, false, 0, true);
    }

    function removeShares(Side side, uint16 tick, uint128 sharesToBurn)
        external
        returns (uint96 removedLots)
    {
        MakerQuote memory q = quotes[msg.sender][side][tick];
        ModuleLock memory lock = moduleLocks[msg.sender][side][tick];
        uint128 locked = lock.generation == q.generation ? lock.shares : 0;
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
        _requireStandalone();
        filledLots = _takeFor(msg.sender, side, limitTick, lots, policy, false, false);
    }

    function moduleReserveExposure(address account, Side side, uint96 lots)
        external
        override
        onlyRiskModule
        returns (uint16 riskCeilingTick)
    {
        _requirePortfolioControllerIfEnabled();
        if (lots == 0) revert ZeroAmount();

        _adjustRisk(account, side, lots, true);

        riskCeilingTick =
            OrderBookMath.upperTick(currentMarkTick(), executionBandTicks);

        if (riskCeilingTick > _accountMeta[account].riskCeilingTick) {
            _accountMeta[account].riskCeilingTick = riskCeilingTick;
        }

        _refreshReservedMargin(account);
    }

    function moduleReleaseExposure(address account, Side side, uint96 lots)
        external
        override
        onlyRiskModule
    {
        if (lots == 0) return;
        _adjustRisk(account, side, lots, false);
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
    ) external override onlyRiskModule returns (uint96 filledLots) {
        if (!reduceOnly) _requirePortfolioControllerIfEnabled();
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
    ) external override onlyRiskModule returns (uint128 mintedShares) {
        _requirePortfolioControllerIfEnabled();
        mintedShares =
            _addLiquidityFor(account, side, tick, lots, true, reservedRiskCeiling, true);

        uint32 generation = pools[side][tick].generation;
        ModuleLock storage lock = moduleLocks[account][side][tick];
        if (lock.generation != generation) {
            lock.generation = generation;
            lock.shares = 0;
        }
        lock.shares += mintedShares;
    }

    function moduleSettle(address account, Side side, uint16 tick)
        external
        override
        onlyRiskModule
        returns (uint96 filledLots)
    {
        filledLots = _settle(account, side, tick);
        _settleExistingPositionFunding(account);
    }

    function moduleRemoveLockedShares(
        address account,
        Side side,
        uint16 tick,
        uint32 generation,
        uint128 shares
    ) external override onlyRiskModule returns (uint96 removedLots) {
        ModuleLock storage lock = moduleLocks[account][side][tick];
        if (
            shares == 0 || lock.generation != generation
                || pools[side][tick].generation != generation || shares > lock.shares
        ) revert InvalidShareAmount();

        _decreaseModuleLock(account, side, tick, shares);

        removedLots = _removeSharesFor(account, side, tick, shares);
    }

    function moduleUnlockShares(
        address account,
        Side side,
        uint16 tick,
        uint32 generation,
        uint128 shares
    ) external override onlyRiskModule {
        ModuleLock storage lock = moduleLocks[account][side][tick];

        // The referenced generation can already be fully consumed and replaced.
        // In that case its shares no longer exist and must not touch the new lock.
        if (lock.generation != generation) return;
        if (shares > lock.shares) revert InvalidShareAmount();

        _decreaseModuleLock(account, side, tick, shares);
    }

    function _decreaseModuleLock(
        address account,
        Side side,
        uint16 tick,
        uint128 shares
    ) internal {
        ModuleLock storage lock = moduleLocks[account][side][tick];
        lock.shares -= shares;
        if (lock.shares == 0) delete moduleLocks[account][side][tick];
    }

    function moduleForceCancelQuote(address account, Side side, uint16 tick)
        external
        override
        onlyModule
        returns (uint96 removedLots)
    {
        _settle(account, side, tick);

        MakerQuote storage q = quotes[account][side][tick];
        if (q.shares == 0) {
            delete moduleLocks[account][side][tick];
            return 0;
        }

        uint128 shares = q.shares;
        removedLots = _removeSharesFor(account, side, tick, shares);
        delete moduleLocks[account][side][tick];
    }

    function moduleCoverBadDebt(address account, uint256 requested)
        external
        override
        onlyModule
        returns (uint256 covered)
    {
        _requireStandalone();
        if (requested == 0) return 0;
        if (_accountMeta[account].activeQuoteCount != 0) revert Unauthorized();

        int80 position = accountRisk[account].settledPosition;
        if (position != 0) revert ReduceOnlyViolation();

        int256 equity = accountEquity(account);
        if (equity >= 0) return 0;

        uint256 debt = uint256(-equity);
        covered = requested < debt ? requested : debt;

        uint256 reserves = insuranceReserves;
        if (covered > reserves) covered = reserves;
        if (covered == 0) return 0;

        insuranceReserves = reserves - covered;
        collateralBalance[account] += covered;
        totalLocalCollateral += covered;

        emit BadDebtCovered(account, covered);
    }

    function modulePayLiquidationReward(address liquidator, uint256 requested)
        external
        override
        onlyModule
        returns (uint256 paid)
    {
        if (liquidator == address(0) || requested == 0) return 0;

        uint256 packed = _feeAccountingPacked;
        uint256 accrued = uint256(uint128(packed));
        paid = requested < accrued ? requested : accrued;
        if (paid == 0) return 0;

        _feeAccountingPacked =
            (packed & ~uint256(type(uint128).max)) | (accrued - paid);
        _transferCollateralOut(liquidator, paid);

        emit LiquidationRewardPaid(liquidator, paid);
    }

    function accountMarketValue(address account)
        public
        view
        override
        returns (int256 value)
    {
        AccountRisk memory a = accountRisk[account];

        int256 pendingFunding =
            -(int256(a.settledPosition)
                * (int256(fundingIndexX18)
                    - int256(_accountMeta[account].fundingCheckpointX18))
                / FUNDING_SCALE);

        int256 markedPositionValue;
        if (a.settledPosition != 0) {
            uint96 absLots = uint96(uint80(OrderBookMath.absPosition(a.settledPosition)));
            int256 marked = int256(notionalValue(absLots, currentMarkTick()));
            markedPositionValue = a.settledPosition > 0 ? marked : -marked;
        }

        value = tradeCashflow[account] + fundingCashflow[account]
            + pendingFunding + markedPositionValue;
    }

    function accountEquity(address account) public view override returns (int256 equity) {
        equity = int256(collateralBalance[account]) + accountMarketValue(account);
    }

    function notionalValue(uint96 lots, uint16 tick)
        public
        view
        override
        returns (uint256)
    {
        return uint256(lots) * uint256(tick) * uint256(collateralUnitsPerLotTick);
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
        uint256 reservedMakerRebate;
        (filledLots, notional, reservedMakerRebate) =
            _match(account, takerSide, makerSide, limitTick, executableLots);

        if (policy == FillPolicy.FOK && filledLots != executableLots) {
            revert InsufficientLiquidity();
        }

        if (filledLots != 0) {
            _applyImmediateTakerFill(
                account,
                takerSide,
                filledLots,
                notional,
                reservedMakerRebate,
                preReserved
            );
        }
    }

    function _match(
        address account,
        Side takerSide,
        Side makerSide,
        uint16 limitTick,
        uint96 executableLots
    ) internal returns (
        uint96 filledLots,
        uint256 notional,
        uint256 reservedMakerRebate
    ) {
        uint96 remaining = executableLots;

        while (remaining != 0) {
            (bool ok, uint16 tick) = _bestExecutableTick(makerSide);
            if (!ok || !OrderBookMath.withinLimit(makerSide, tick, limitTick)) break;

            (uint96 fill, uint256 fillMakerRebate) =
                _consumeTick(makerSide, tick, remaining);
            unchecked {
                remaining -= fill;
                filledLots += fill;
            }

            reservedMakerRebate += fillMakerRebate;
            notional += notionalValue(fill, tick);
            emit Trade(account, takerSide, tick, fill);
        }
    }

    function _consumeTick(Side makerSide, uint16 tick, uint96 requested)
        internal
        returns (uint96 fill, uint256 reservedMakerRebate)
    {
        TickPool storage p = pools[makerSide][tick];
        fill = requested < p.remainingLots ? requested : p.remainingLots;

        reservedMakerRebate =
            notionalValue(fill, tick) * uint256(uint16(feeSchedulePacked >> 16)) / 10_000;
        if (reservedMakerRebate != 0) {
            uint256 nextReserve = uint256(currentMakerRebateReserve[makerSide][tick]) + reservedMakerRebate;
            if (nextReserve > type(uint128).max) revert Overflow();
            currentMakerRebateReserve[makerSide][tick] = uint128(nextReserve);
        }

        _recordFundingEntry(makerSide, tick, p.totalShares, fill);
        generationMakerFillBudget[makerSide][tick][p.generation] += fill;
        p.remainingLots -= fill;

        if (p.remainingLots != 0) return (fill, reservedMakerRebate);

        uint32 oldGeneration = p.generation;
        closedFundingEntryPerShareX96[makerSide][tick][oldGeneration] =
            fundingEntryPerShareX96[makerSide][tick];
        closedGenerationAccounting[makerSide][tick][oldGeneration] =
            (uint256(currentMakerRebateReserve[makerSide][tick]) << 128) | uint256(p.totalShares);
        fundingEntryPerShareX96[makerSide][tick] = 0;

        p.totalShares = 0;
        delete currentMakerRebateReserve[makerSide][tick];
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
            _adjustRisk(maker, side, lots, true);
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
        if (redeemed > type(uint96).max) revert InvalidShareAmount();

        removedLots = uint96(redeemed);

        uint96 claimBefore = q.claimLots;
        uint96 remainingBefore = p.remainingLots;

        p.totalShares -= sharesToBurn;
        p.remainingLots = remainingBefore - removedLots;
        q.shares -= sharesToBurn;

        uint96 claimAfter;
        if (q.shares != 0) {
            claimAfter = OrderBookMath.redeemableLotsCeil(
                q.shares,
                p.remainingLots,
                p.totalShares
            );
        }
        if (claimAfter > claimBefore) claimAfter = claimBefore;

        uint96 claimReduction = claimBefore - claimAfter;
        if (claimReduction < removedLots) {
            uint256 otherShares = uint256(p.totalShares) - uint256(q.shares);
            if (otherShares == 0) {
                removedLots = claimReduction;
                p.remainingLots = remainingBefore - removedLots;
            } else {
                uint256 safeLeft =
                    uint256(claimBefore) * uint256(p.totalShares);
                uint256 safeRight =
                    uint256(q.shares) * uint256(remainingBefore);
                uint256 safeNumerator =
                    safeLeft > safeRight ? safeLeft - safeRight : 0;
                uint96 maxSafeRemoval =
                    uint96(safeNumerator / otherShares);
                if (removedLots > maxSafeRemoval) {
                    removedLots = maxSafeRemoval;
                    p.remainingLots = remainingBefore - removedLots;

                    claimAfter = q.shares == 0
                        ? 0
                        : OrderBookMath.redeemableLotsCeil(
                            q.shares,
                            p.remainingLots,
                            p.totalShares
                        );
                    if (claimAfter > claimBefore) claimAfter = claimBefore;
                    claimReduction = claimBefore - claimAfter;
                }
            }
        }
        if (claimReduction < removedLots) revert InvalidShareAmount();
        q.claimLots = claimAfter;

        // _settle() above materializes every maker fill visible before
        // this cancellation. A share burn may expose an additional historical
        // fill through ceil/floor rounding, but it may consume only execution
        // budget created by actual taker fills in this generation.
        uint96 availableFill =
            generationMakerFillBudget[side][tick][q.generation];
        uint96 burnAttributedFill = claimReduction - removedLots;
        if (burnAttributedFill > availableFill) {
            burnAttributedFill = availableFill;
        }

        if (burnAttributedFill != 0) {
            int256 currentFundingEntry =
                fundingEntryPerShareX96[side][tick];
            _settleFundingForQuote(
                maker,
                side,
                tick,
                sharesToBurn,
                burnAttributedFill,
                currentFundingEntry
            );
            _applyMakerFill(
                maker,
                side,
                tick,
                burnAttributedFill,
                q.generation
            );
            emit MakerSettled(
                maker,
                side,
                tick,
                burnAttributedFill,
                q.generation
            );
        }

        // Pure cancellation must transfer the burned shares' pending
        // funding basis onto survivors. If this burn actually crystallized
        // historical fill, _settleFundingForQuote already consumed the burned
        // slice's basis, so inheriting it again would double count funding.
        if (burnAttributedFill == 0 && q.shares != 0) {
            int256 currentFundingEntry = fundingEntryPerShareX96[side][tick];
            int256 priorCheckpoint =
                quoteFundingCheckpointX96[maker][side][tick];
            int256 pendingEntryPerShare =
                currentFundingEntry - priorCheckpoint;

            if (pendingEntryPerShare != 0) {
                int256 inheritedEntryPerShare = _divFundingDirected(
                    side,
                    int256(uint256(q.shares + sharesToBurn))
                        * pendingEntryPerShare,
                    int256(uint256(q.shares))
                );
                quoteFundingCheckpointX96[maker][side][tick] =
                    currentFundingEntry - inheritedEntryPerShare;
            }
        }

        _adjustRisk(maker, side, removedLots, false);

        // Apply residual real execution only after cancellation has reduced
        // the quote envelope, so the tail can clamp the final settled position
        // back inside min/max rather than being shrunk out of the envelope.
        if (p.totalShares == 0) {
            _settleMakerRoundingTail(maker, side, tick, q.generation);
        }

        _refreshReservedMargin(maker);

        if (q.shares == 0) {
            _clearQuote(maker, side, tick);
        }

        if (p.totalShares == 0) {
            p.remainingLots = 0;

            uint128 rebateDust = currentMakerRebateReserve[side][tick];
            if (rebateDust != 0) {
                _reclaimMakerRebateDust(rebateDust);
                delete currentMakerRebateReserve[side][tick];
            }

            _setOccupied(side, tick, false);
            delete poolRiskCeilingTick[side][tick];

            unchecked {
                ++p.generation;
            }
        }

        emit LiquidityRemoved(maker, side, tick, removedLots, sharesToBurn, p.generation);
    }

    function _clearQuote(address maker, Side side, uint16 tick) internal {
        delete quotes[maker][side][tick];
        delete quoteFundingCheckpointX96[maker][side][tick];
        _accountMeta[maker].activeQuoteCount -= 1;
    }

    function _preparePoolRiskCeiling(
        address maker,
        Side side,
        uint16 tick,
        bool wasEmpty,
        bool preReserved,
        uint16 reservedRiskCeiling
    ) internal {
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
                    OrderBookMath.upperTick(mark, executionBandTicks);
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
            uint32 oldGeneration = q.generation;
            uint128 outstanding =
                uint128(closedGenerationAccounting[side][tick][oldGeneration]);

            filledLots = q.claimLots;

            int256 finalFundingEntry =
                closedFundingEntryPerShareX96[side][tick][oldGeneration];

            _settleFundingForQuote(
                maker, side, tick, q.shares, filledLots, finalFundingEntry
            );
            _applyMakerFill(maker, side, tick, filledLots, oldGeneration);
            if (outstanding == q.shares) {
                filledLots +=
                    _settleMakerRoundingTail(maker, side, tick, oldGeneration);
            }
            _refreshReservedMargin(maker);

            uint256 closedAccounting =
                closedGenerationAccounting[side][tick][oldGeneration];
            outstanding = uint128(closedAccounting);

            if (outstanding >= q.shares) {
                outstanding -= q.shares;
                uint128 rebateReserve = uint128(closedAccounting >> 128);

                if (outstanding == 0) {
                    if (rebateReserve != 0) {
                        _reclaimMakerRebateDust(rebateReserve);
                    }
                    delete closedGenerationAccounting[side][tick][oldGeneration];
                    delete closedFundingEntryPerShareX96[side][tick][oldGeneration];
                } else {
                    closedGenerationAccounting[side][tick][oldGeneration] =
                        (uint256(rebateReserve) << 128) | uint256(outstanding);
                }
            }

            _clearQuote(maker, side, tick);

            emit MakerSettled(maker, side, tick, filledLots, oldGeneration);
            return filledLots;
        }

        uint96 currentClaim =
            OrderBookMath.redeemableLotsCeil(q.shares, p.remainingLots, p.totalShares);

        // claimLots is a monotonic remaining fill entitlement. Another
        // maker burning shares can increase the instantaneous ceil redemption,
        // but promoting that rounding headroom into claimLots would later turn
        // cancellation dust into synthetic maker fills.
        if (currentClaim >= q.claimLots) return 0;

        filledLots = q.claimLots - currentClaim;
        q.claimLots = currentClaim;

        int256 currentFundingEntry = fundingEntryPerShareX96[side][tick];

        _settleFundingForQuote(
            maker, side, tick, q.shares, filledLots, currentFundingEntry
        );
        quoteFundingCheckpointX96[maker][side][tick] = currentFundingEntry;

        _applyMakerFill(maker, side, tick, filledLots, q.generation);
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

        uint256 fillNumerator = uint256(fillLots) * ACCUMULATOR_SCALE;
        bool roundFillUp =
            (side == Side.Ask) == (fundingIndexX18 >= 0);

        uint256 fillPerShareX96 = roundFillUp
            ? (fillNumerator + uint256(totalShares) - 1) / uint256(totalShares)
            : fillNumerator / uint256(totalShares);

        int256 weighted = _divFundingDirected(
            side,
            int256(fillPerShareX96) * int256(fundingIndexX18),
            FUNDING_SCALE
        );

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

        int256 weightedEntry = _divFundingDirected(
            side,
            int256(uint256(shares)) * deltaPerShare,
            int256(ACCUMULATOR_SCALE)
        );

        int256 signedLots =
            side == Side.Bid ? int256(uint256(filledLots)) : -int256(uint256(filledLots));

        int256 currentFunding = _divFundingCeil(
            signedLots * int256(fundingIndexX18),
            FUNDING_SCALE
        );

        int256 entryFunding =
            signedLots == 0 ? int256(0) : (signedLots > 0 ? weightedEntry : -weightedEntry);

        int256 cashflowDelta = entryFunding - currentFunding;

        if (cashflowDelta != 0) {
            fundingCashflow[maker] += cashflowDelta;
            emit FundingSettled(maker, cashflowDelta);
        }

        _accountMeta[maker].fundingCheckpointX18 = fundingIndexX18;
    }

    function _debitSettledCash(address account, uint256 amount) internal {
        uint256 balance = collateralBalance[account];
        if (amount <= balance) {
            collateralBalance[account] = balance - amount;
            return;
        }

        uint256 remainder = amount - balance;
        collateralBalance[account] = 0;

        int256 trading = tradeCashflow[account];
        if (trading > 0) {
            uint256 available = uint256(trading);
            uint256 debit = remainder < available ? remainder : available;
            tradeCashflow[account] = trading - int256(debit);
            remainder -= debit;
        }

        if (remainder != 0) {
            int256 funding = fundingCashflow[account];
            if (funding <= 0 || uint256(funding) < remainder) {
                revert InsufficientCollateral();
            }
            fundingCashflow[account] = funding - int256(remainder);
        }
    }

    function _settleExistingPositionFunding(address account) internal {
        int128 currentIndex = fundingIndexX18;
        int128 checkpoint = _accountMeta[account].fundingCheckpointX18;

        if (currentIndex == checkpoint) return;

        int256 position = int256(accountRisk[account].settledPosition);
        int256 deltaIndex = int256(currentIndex) - int256(checkpoint);

        if (position != 0) {
            int256 fundingNumerator = -(position * deltaIndex);
            int256 cashflowDelta = fundingNumerator / FUNDING_SCALE;
            if (
                fundingNumerator < 0
                    && fundingNumerator % FUNDING_SCALE != 0
            ) {
                --cashflowDelta;
            }
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
        uint256 reservedMakerRebate,
        bool preReserved
    ) internal {
        _settleExistingPositionFunding(account);

        AccountRisk storage a = accountRisk[account];
        int80 amount = _positionAmount(filledLots);

        uint32 fees = feeSchedulePacked;
        uint256 takerFee =
            notional * uint256(uint16(fees)) / 10_000;
        if (reservedMakerRebate > takerFee) revert InvalidRiskConfig();

        uint256 packedFees = _feeAccountingPacked;
        uint256 accruedProtocol = uint256(uint128(packedFees));
        uint256 rebateReserve = packedFees >> 128;
        uint256 nextProtocol =
            accruedProtocol + takerFee - reservedMakerRebate;
        uint256 nextRebateReserve =
            rebateReserve + reservedMakerRebate;
        if (
            nextProtocol > type(uint128).max
                || nextRebateReserve > type(uint128).max
        ) revert Overflow();
        _feeAccountingPacked =
            (nextRebateReserve << 128) | nextProtocol;

        if (side == Side.Bid) {
            a.settledPosition += amount;
            a.minPosition += amount;
            if (!preReserved) a.maxPosition += amount;
            tradeCashflow[account] -= int256(notional + takerFee);
        } else {
            a.settledPosition -= amount;
            a.maxPosition -= amount;
            if (!preReserved) a.minPosition -= amount;
            tradeCashflow[account] += int256(notional) - int256(takerFee);
        }

        _refreshReservedMargin(account);
    }

    function _applyMakerFill(
        address maker,
        Side side,
        uint16 tick,
        uint96 filledLots,
        uint32 generation
    ) internal {
        if (filledLots == 0) return;

        generationMakerFillBudget[side][tick][generation] -= filledLots;

        uint256 notional = notionalValue(filledLots, tick);
        uint256 requestedMakerRebate =
            notional * uint256(uint16(feeSchedulePacked >> 16)) / 10_000;
        TickPool storage p = pools[side][tick];
        uint256 localReserve;
        bool currentGeneration = generation == p.generation;
        if (currentGeneration) {
            localReserve = currentMakerRebateReserve[side][tick];
        } else {
            localReserve =
                uint128(closedGenerationAccounting[side][tick][generation] >> 128);
        }

        uint256 packedFees = _feeAccountingPacked;
        uint256 availableMakerRebate = packedFees >> 128;
        uint256 makerRebate = requestedMakerRebate;
        if (makerRebate > localReserve) makerRebate = localReserve;
        if (makerRebate > availableMakerRebate) makerRebate = availableMakerRebate;

        if (makerRebate != 0) {
            _feeAccountingPacked =
                (packedFees & uint256(type(uint128).max))
                    | ((availableMakerRebate - makerRebate) << 128);

            if (currentGeneration) {
                currentMakerRebateReserve[side][tick] =
                    uint128(localReserve - makerRebate);
            } else {
                uint256 closedAccounting =
                    closedGenerationAccounting[side][tick][generation];
                closedGenerationAccounting[side][tick][generation] =
                    ((localReserve - makerRebate) << 128)
                        | uint256(uint128(closedAccounting));
            }
        }

        _applyMakerPositionCashflow(
            maker, side, filledLots, notional, makerRebate, false
        );
    }

    function _settleMakerRoundingTail(
        address maker,
        Side side,
        uint16 tick,
        uint32 generation
    ) internal returns (uint96 tail) {
        tail = generationMakerFillBudget[side][tick][generation];
        if (tail == 0) return 0;
        generationMakerFillBudget[side][tick][generation] = 0;
        _applyMakerPositionCashflow(
            maker, side, tail, notionalValue(tail, tick), 0, true
        );
        emit MakerSettled(maker, side, tick, tail, generation);
    }

    function _applyMakerPositionCashflow(
        address maker,
        Side side,
        uint96 filledLots,
        uint256 notional,
        uint256 makerRebate,
        bool widen
    ) internal {
        AccountRisk storage a = accountRisk[maker];
        int80 amount = _positionAmount(filledLots);

        if (side == Side.Bid) {
            a.settledPosition += amount;
            a.minPosition += amount;
            if (widen && a.maxPosition < a.settledPosition) {
                a.maxPosition = a.settledPosition;
            }
            tradeCashflow[maker] += int256(makerRebate) - int256(notional);
        } else {
            a.settledPosition -= amount;
            a.maxPosition -= amount;
            if (widen && a.minPosition > a.settledPosition) {
                a.minPosition = a.settledPosition;
            }
            tradeCashflow[maker] += int256(notional + makerRebate);
        }
    }

    function _reclaimMakerRebateDust(uint256 amount) internal {
        uint256 packedFees = _feeAccountingPacked;
        uint256 protocol = uint256(uint128(packedFees));
        uint256 reserve = packedFees >> 128;
        if (amount > reserve) revert InvalidRiskConfig();

        uint256 nextProtocol = protocol + amount;
        if (nextProtocol > type(uint128).max) revert Overflow();

        _feeAccountingPacked =
            ((reserve - amount) << 128) | nextProtocol;
    }

    function _adjustRisk(
        address account,
        Side side,
        uint96 lots,
        bool expand
    ) internal {
        AccountRisk storage a = accountRisk[account];
        int80 amount = _positionAmount(lots);

        if (side == Side.Bid) {
            if (expand) a.maxPosition += amount;
            else a.maxPosition -= amount;
        } else {
            if (expand) a.minPosition -= amount;
            else a.minPosition += amount;
        }
    }

    function _refreshReservedMargin(address account) internal {
        AccountRisk memory a = accountRisk[account];

        uint256 absMin = uint256(OrderBookMath.absPosition(a.minPosition));
        uint256 absMax = uint256(OrderBookMath.absPosition(a.maxPosition));

        uint256 worstLots = absMin > absMax ? absMin : absMax;

        AccountMeta storage meta = _accountMeta[account];
        if (
            a.minPosition == a.settledPosition
                && a.maxPosition == a.settledPosition
        ) {
            meta.riskCeilingTick = 0;
        }

        uint256 worstPrice = meta.riskCeilingTick;
        if (worstPrice == 0) {
            worstPrice = uint256(
                OrderBookMath.upperTick(currentMarkTick(), executionBandTicks)
            );
        }

        uint256 worstNotional =
            uint256(worstLots) * worstPrice * uint256(collateralUnitsPerLotTick);
        uint256 required =
            worstNotional * uint256(initialMarginBps) / 10_000;

        uint256 previous = reservedMargin[account];

        if (
            portfolioController == address(0) && required > previous
                && accountEquity(account) < int256(required)
        ) {
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
        uint16 mark = currentMarkTick();
        uint16 lower =
            mark > executionBandTicks ? mark - executionBandTicks : 0;
        uint16 upper = OrderBookMath.upperTick(mark, executionBandTicks);

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

        uint8 wordIndex = _edgeBit(side, words);
        uint256 word = _tickWords[side][wordIndex];
        uint8 bitIndex = _edgeBit(side, word);

        return (
            true,
            (uint16(wordIndex) << 8) | uint16(bitIndex)
        );
    }

    function _nextTick(Side side, uint16 current)
        internal
        view
        returns (bool ok, uint16 tick)
    {
        uint8 wi = uint8(current >> 8);
        uint8 bi = uint8(current);
        uint256 word = _tickWords[side][wi];

        if (side == Side.Ask) {
            uint256 sameWord =
                word & (type(uint256).max << (uint256(bi) + 1));
            if (sameWord != 0) {
                return (true, (uint16(wi) << 8) | uint16(_edgeBit(side, sameWord)));
            }

            uint256 higherWords =
                _occupiedWords[side]
                    & (type(uint256).max << (uint256(wi) + 1));
            if (higherWords == 0) return (false, 0);

            wi = _edgeBit(side, higherWords);
            return (
                true,
                (uint16(wi) << 8) | uint16(_edgeBit(side, _tickWords[side][wi]))
            );
        }

        uint256 sameWord = word & ((uint256(1) << bi) - 1);
        if (sameWord != 0) {
            return (true, (uint16(wi) << 8) | uint16(_edgeBit(side, sameWord)));
        }

        uint256 lowerWords =
            _occupiedWords[side] & ((uint256(1) << wi) - 1);
        if (lowerWords == 0) return (false, 0);

        wi = _edgeBit(side, lowerWords);
        return (
            true,
            (uint16(wi) << 8) | uint16(_edgeBit(side, _tickWords[side][wi]))
        );
    }

    function _edgeBit(Side side, uint256 x) internal pure returns (uint8) {
        return side == Side.Ask ? _lsb(x) : _msb(x);
    }

    function _lsb(uint256 x) internal pure returns (uint8 r) {
        unchecked {
            r = _msb(x & (~x + 1));
        }
    }

    function _msb(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert InsufficientLiquidity();

        assembly {
            let f := shl(7, iszero(iszero(shr(128, x))))
            x := shr(f, x)
            r := f

            f := shl(6, iszero(iszero(shr(64, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(5, iszero(iszero(shr(32, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(4, iszero(iszero(shr(16, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(3, iszero(iszero(shr(8, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(2, iszero(iszero(shr(4, x))))
            x := shr(f, x)
            r := or(r, f)

            f := shl(1, iszero(iszero(shr(2, x))))
            x := shr(f, x)
            r := or(r, f)

            r := or(r, iszero(iszero(shr(1, x))))
        }
    }

    function _divFundingCeil(int256 numerator, int256 denominator)
        internal
        pure
        returns (int256 quotient)
    {
        quotient = numerator / denominator;
        if (numerator > 0 && numerator % denominator != 0) {
            ++quotient;
        }
    }

    function _divFundingDirected(
        Side side,
        int256 numerator,
        int256 denominator
    ) internal pure returns (int256 quotient) {
        quotient = numerator / denominator;
        int256 remainder = numerator % denominator;
        if (remainder == 0) return quotient;

        if (side == Side.Bid) {
            if (numerator < 0) --quotient;
        } else if (numerator > 0) {
            ++quotient;
        }
    }

}

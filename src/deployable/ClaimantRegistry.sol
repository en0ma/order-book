// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Append-only claimant index, owned by one fixed custody/accounting contract.
/// @dev Constructed by the registrar itself; owner/operator cannot replace provenance.
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

interface IRegisteredStandaloneCore {
    function portfolioController() external view returns (address);
    function riskIncreasePaused() external view returns (bool);
    function accountRisk(address account) external view returns (
        int80 settledPosition, int80 minPosition, int80 maxPosition
    );
    function activeQuoteCount(address account) external view returns (uint32);
    function advancedModule() external view returns (address);
    function accountEquity(address account) external view returns (int256);
    function insuranceReserves() external view returns (uint256);
    function pendingMakerRebateReserve() external view returns (uint256);
    function protocolFeesAccrued() external view returns (uint256);
    function collateralAsset() external view returns (address);
    function currentMarkTick() external view returns (uint16);
    function notionalValue(uint96 lots, uint16 tick) external view returns (uint256);
    function currentFundingIndexX18() external view returns (int128);
    function pendingMakerRoundingLiability() external view returns (uint256);
}

interface IRegisteredAdvancedOrders {
    function activeAdvancedOrders(address account) external view returns (uint32);
}

contract ClaimantRegistry {
    error UnauthorizedRegistrar();
    error InvalidClaimant();
    error UnsettledExposure();
    error PortfolioNotStandalone();
    error ExcessiveClaimantCount();
    uint256 internal constant MAX_PROOF_ACCOUNTS = 64;

    address public immutable registrar;
    address[] internal _accounts;
    mapping(address => bool) internal _seen;
    // Unsigned, non-nettable upper bounds for still-unattributed maker fills.
    // Funding bases are deliberately monotone until separately proven settled;
    // this can reduce capacity but can never turn historical funding into surplus.
    uint256 public pendingMakerUnattributedLots;
    uint256 public makerFundingBasisUpper;
    mapping(uint32 => uint256) internal _pendingLotsBySideTick;
    mapping(uint32 => uint256) internal _pendingActiveIndexPlusOne;
    uint32[] internal _pendingActiveTicks;
    uint256 internal constant MAX_PENDING_PRICE_LEVELS = 64;


    event ClaimantRecorded(address indexed account, uint256 indexed index);

    constructor() {
        registrar = msg.sender;
    }

    function record(address account) external {
        if (msg.sender != registrar) revert UnauthorizedRegistrar();
        if (account == address(0)) revert InvalidClaimant();
        if (_seen[account]) return;

        _seen[account] = true;
        uint256 index = _accounts.length;
        _accounts.push(account);
        emit ClaimantRecorded(account, index);
    }

    function count() external view returns (uint256) {
        return _accounts.length;
    }

    function at(uint256 index) external view returns (address) {
        return _accounts[index];
    }

    function contains(address account) external view returns (bool) {
        return _seen[account];
    }
    /// @notice Physically backed candidate distributable fees, calculated only
    /// against the registrar's immutable, append-only account universe.
    /// @dev Refuse any exposure rather than guessing unrealized maker/funding PnL.
    ///      The caller must enforce authorization and recheck backing after transfer.
    function standaloneFeeCapacity()
        external
        view
        returns (uint256 capacity, uint256 positiveClaims, uint256 protectedLiabilities)
    {
        IRegisteredStandaloneCore core = IRegisteredStandaloneCore(registrar);
        if (core.portfolioController() != address(0)) revert PortfolioNotStandalone();
        if (core.riskIncreasePaused()) revert UnsettledExposure();

        uint256 length = _accounts.length;
        if (length > MAX_PROOF_ACCOUNTS) revert ExcessiveClaimantCount();
        address advanced = core.advancedModule();
        for (uint256 i; i < length; ++i) {
            address account = _accounts[i];
            (int80 position, int80 minPosition, int80 maxPosition) = core.accountRisk(account);
            if (
                position != 0 || minPosition != 0 || maxPosition != 0
                    || core.activeQuoteCount(account) != 0
                    || (advanced != address(0)
                        && IRegisteredAdvancedOrders(advanced).activeAdvancedOrders(account) != 0)
            ) revert UnsettledExposure();
            int256 cash = core.accountEquity(account);
            if (cash > 0) positiveClaims += uint256(cash);
        }

        protectedLiabilities = positiveClaims + core.insuranceReserves()
            + core.pendingMakerRebateReserve();
        uint256 balance = IERC20Minimal(core.collateralAsset()).balanceOf(registrar);
        if (balance <= protectedLiabilities) return (0, positiveClaims, protectedLiabilities);
        uint256 unencumbered = balance - protectedLiabilities;
        uint256 fees = core.protocolFeesAccrued();
        capacity = unencumbered < fees ? unencumbered : fees;
    }

    /// @dev Side/tick buckets cannot cancel each other's positive maker PnL.
    function recordPendingMaker(bool makerBid, uint16 tick, uint96 lots, int256 fundingEntry)
        external
    {
        if (msg.sender != registrar) revert UnauthorizedRegistrar();
        uint32 key = uint32(tick) | (makerBid ? uint32(1) << 16 : 0);
        if (_pendingLotsBySideTick[key] == 0) {
            _pendingActiveTicks.push(key);
            _pendingActiveIndexPlusOne[key] = _pendingActiveTicks.length;
        }
        _pendingLotsBySideTick[key] += lots;
        pendingMakerUnattributedLots += lots;
        makerFundingBasisUpper += _abs(fundingEntry);
    }

    function settlePendingMaker(bool makerBid, uint16 tick, uint96 lots) external {
        if (msg.sender != registrar) revert UnauthorizedRegistrar();
        if (lots == 0) return;
        uint32 key = uint32(tick) | (makerBid ? uint32(1) << 16 : 0);
        pendingMakerUnattributedLots -= lots;
        uint256 next = _pendingLotsBySideTick[key] - lots;
        _pendingLotsBySideTick[key] = next;
        if (next != 0) return;

        uint256 position = _pendingActiveIndexPlusOne[key] - 1;
        uint256 last = _pendingActiveTicks.length - 1;
        if (position != last) {
            uint32 shifted = _pendingActiveTicks[last];
            _pendingActiveTicks[position] = shifted;
            _pendingActiveIndexPlusOne[shifted] = position + 1;
        }
        _pendingActiveTicks.pop();
        delete _pendingActiveIndexPlusOne[key];
    }

    function pendingPriceLevelCount() external view returns (uint256) {
        return _pendingActiveTicks.length;
    }

    /// @notice Conservative collateral floor for liquidation rewards with
    /// open positions and lazily attributed maker fills. Unlike treasury,
    /// a reward may be partially paid or skipped when proof gas is bounded.
    function conservativeRewardCapacity()
        external
        view
        returns (uint256 available, uint256 claims, uint256 protectedLiabilities)
    {
        IRegisteredStandaloneCore core = IRegisteredStandaloneCore(registrar);
        if (core.portfolioController() != address(0)) revert PortfolioNotStandalone();
        if (_accounts.length > MAX_PROOF_ACCOUNTS) return (0, 0, type(uint256).max);

        for (uint256 i; i < _accounts.length; ++i) {
            int256 equity = core.accountEquity(_accounts[i]);
            if (equity > 0) claims += uint256(equity);
        }

        // Gross pending maker value is an upper bound: a pending buyer cannot
        // gain more than gross marked long value, a pending seller cannot
        // gain more than execution proceeds. No opposite-side offset is used.
        if (_pendingActiveTicks.length > MAX_PENDING_PRICE_LEVELS) {
            return (0, 0, type(uint256).max);
        }
        uint16 mark = core.currentMarkTick();
        uint256 unitScale = core.notionalValue(1, 1);
        uint256 pendingPriceBound;
        for (uint256 i; i < _pendingActiveTicks.length; ++i) {
            uint32 key = _pendingActiveTicks[i];
            uint16 executionTick = uint16(key);
            bool makerBid = key >> 16 != 0;
            // Each bucket contains only one side at one execution price.
            // Take its favorable PnL separately; no signed cross-bucket netting.
            if (makerBid && mark > executionTick) {
                pendingPriceBound += uint256(mark - executionTick)
                    * _pendingLotsBySideTick[key] * unitScale;
            } else if (!makerBid && executionTick > mark) {
                pendingPriceBound += uint256(executionTick - mark)
                    * _pendingLotsBySideTick[key] * unitScale;
            }
        }

        // Each deferred fill's current-index funding is bounded by its
        // gross entry basis plus absolute index times gross lots. One unit
        // per pending lot protects per-share directed rounding.
        int256 fundingIndex = int256(core.currentFundingIndexX18());
        uint256 indexMagnitude = _abs(fundingIndex);
        uint256 fundingBound =
            (pendingMakerUnattributedLots * indexMagnitude + 1e18 - 1) / 1e18
                + pendingMakerUnattributedLots + makerFundingBasisUpper;

        protectedLiabilities = claims + core.insuranceReserves()
            + core.pendingMakerRebateReserve() + pendingPriceBound
            + fundingBound + core.pendingMakerRoundingLiability();

        uint256 custody = IERC20Minimal(core.collateralAsset()).balanceOf(registrar);
        if (custody <= protectedLiabilities) return (0, claims, protectedLiabilities);
        uint256 unencumbered = custody - protectedLiabilities;
        uint256 accrued = core.protocolFeesAccrued();
        available = accrued < unencumbered ? accrued : unencumbered;
    }

    function _abs(int256 value) internal pure returns (uint256) {
        if (value >= 0) return uint256(value);
        // Cannot negate type(int256).min in signed arithmetic.
        return uint256(-(value + 1)) + 1;
    }

}

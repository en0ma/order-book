// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Append-only claimant index, owned by one fixed custody/accounting contract.
/// @dev Constructed by the registrar itself; owner/operator cannot replace provenance.
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

interface IRegisteredStandaloneCore {
    function portfolioController() external view returns (address);
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

}

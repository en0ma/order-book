// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "./OrderBookCore.sol";
import {ClaimantRegistry} from "./ClaimantRegistry.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

interface IActiveFeeProofOrders {
    function activeAdvancedOrders(address account) external view returns (uint32);
}

/// @notice Conservative proof of available fee backing for an entirely
/// flat, fully-closed standalone book at the time of the call.
/// @dev A read-only prerequisite, NOT payout authorization. This contract
/// rejects active positions and all quote/risk envelopes rather than
/// guessing about unsettled maker and open-position funding liabilities.
/// Payout integration additionally needs a reentrancy-safe atomic gate.
contract StandaloneFeeSolvencyPreflight {
    error PortfolioCustody();
    error UntrustedClaimantRegistry();
    error TooManyClaimants();
    error UnsettledExposure();

    uint256 public constant MAX_CLAIMANTS_PER_PROOF = 64;

    function conservativeCapacity(OrderBookCore core)
        external
        view
        returns (uint256 capacity, uint256 positiveAccountClaims, uint256 protectedReserves)
    {
        if (core.portfolioController() != address(0)) revert PortfolioCustody();
        ClaimantRegistry roster = core.claimantRegistry();
        if (roster.registrar() != address(core)) revert UntrustedClaimantRegistry();

        uint256 count = roster.count();
        if (count > MAX_CLAIMANTS_PER_PROOF) revert TooManyClaimants();

        for (uint256 i; i < count; ++i) {
            positiveAccountClaims += _positiveFlatClaim(core, roster.at(i));
        }

        protectedReserves = positiveAccountClaims + core.insuranceReserves();
        uint256 physicalCustody =
            IERC20Minimal(core.collateralAsset()).balanceOf(address(core));

        if (physicalCustody <= protectedReserves) return (0, positiveAccountClaims, protectedReserves);
        uint256 unencumbered = physicalCustody - protectedReserves;
        uint256 accrued = core.protocolFeesAccrued();
        capacity = accrued < unencumbered ? accrued : unencumbered;
    }
    function _positiveFlatClaim(OrderBookCore core, address claimant)
        internal
        view
        returns (uint256)
    {
        (int80 position, int80 minPosition, int80 maxPosition) = core.accountRisk(claimant);
        if (position != 0 || minPosition != 0 || maxPosition != 0
            || core.activeQuoteCount(claimant) != 0) revert UnsettledExposure();
        address advanced = core.advancedModule();
        if (advanced != address(0)
            && IActiveFeeProofOrders(advanced).activeAdvancedOrders(claimant) != 0) {
            revert UnsettledExposure();
        }
        int256 cash = core.accountEquity(claimant);
        return cash > 0 ? uint256(cash) : 0;
    }

}

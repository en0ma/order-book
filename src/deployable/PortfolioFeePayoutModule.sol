// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioFeeSolvencyPreflight} from "./PortfolioFeeSolvencyPreflight.sol";
import {PortfolioAdmissionCoordinator} from "./PortfolioAdmissionCoordinator.sol";
import {PortfolioCollateralVault} from "./PortfolioCollateralVault.sol";
import {OrderBookCore} from "./OrderBookCore.sol";
import {IOrderBookCore} from "./IOrderBookCore.sol";

/// @notice Immutable, stateless fee-distribution logic for one coordinator.
/// @dev Executed only through the coordinator's guarded delegatecall.
///      No storage writes, no arbitrary external call targets and no
///      caller-supplied verifier are permitted.
contract PortfolioFeePayoutModule {
    error InvalidFeeAllocation();
    error InsufficientFeeBacking();

    PortfolioFeeSolvencyPreflight public immutable proof;

    constructor() {
        proof = new PortfolioFeeSolvencyPreflight();
    }

    function execute(uint256[] calldata marketAmounts)
        external
        returns (uint256 totalPaid)
    {
        PortfolioAdmissionCoordinator context = PortfolioAdmissionCoordinator(address(this));
        uint256 count = context.marketCount();
        if (marketAmounts.length != count) revert InvalidFeeAllocation();
        for (uint256 i; i < count; ++i) totalPaid += marketAmounts[i];
        if (totalPaid == 0) revert InvalidFeeAllocation();

        (uint256 available,,) = proof.conservativeCapacity(context);
        if (totalPaid > available) revert InsufficientFeeBacking();

        for (uint256 i; i < count; ++i) {
            uint256 amount = marketAmounts[i];
            if (amount != 0) {
                (IOrderBookCore marketCore,) = context.markets(i);
                OrderBookCore(address(marketCore)).moduleDebitPortfolioFees(amount);
            }
        }

        PortfolioCollateralVault vault = context.vault();
        vault.controllerPayProtocolFees(context.treasuryRecipient(), totalPaid);

        (,, uint256 protectedLiabilities) = proof.conservativeCapacity(context);
        if (vault.collateralToken().balanceOf(address(vault)) < protectedLiabilities) {
            revert InsufficientFeeBacking();
        }
    }
}

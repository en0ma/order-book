// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioAdmissionCoordinator} from "./PortfolioAdmissionCoordinator.sol";
import {PortfolioMarginPolicy} from "./PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "./PortfolioCollateralVault.sol";
import {OrderBookCore} from "./OrderBookCore.sol";
import {IOrderBookCore} from "./IOrderBookCore.sol";
import {ClaimantRegistry} from "./ClaimantRegistry.sol";

/// @notice Verifies that a managed vault, its policy, and every registered Core
/// share the *same immutable* market topology and contract-owned claimant index.
/// @dev A topology witness is not a liability valuation or payout authorization.
contract PortfolioClaimantTopology {
    error InvalidCustodyTopology();

    function verifyTopology(PortfolioAdmissionCoordinator coordinator)
        external
        view
        returns (uint256 marketCount, uint256 vaultClaimants)
    {
        PortfolioCollateralVault vault = coordinator.vault();
        PortfolioMarginPolicy policy = coordinator.policy();

        if (
            address(vault) == address(0) || address(policy) == address(0)
                || vault.controller() != address(coordinator)
                || address(policy.sharedCollateralVault()) != address(vault)
        ) revert InvalidCustodyTopology();

        marketCount = coordinator.marketCount();
        if (
            marketCount == 0 || marketCount > coordinator.MAX_MARKETS()
                || policy.marketCount() != marketCount
        ) revert InvalidCustodyTopology();

        ClaimantRegistry vaultRegistry = vault.custodyClaimantRegistry();
        if (address(vaultRegistry) == address(0) || vaultRegistry.registrar() != address(vault)) {
            revert InvalidCustodyTopology();
        }
        vaultClaimants = vaultRegistry.count();

        for (uint256 i; i < marketCount; ++i) {
            (IOrderBookCore marketCore, address gateway) = coordinator.markets(i);
            (IOrderBookCore policyCore,,,) = policy.markets(i);
            if (
                address(marketCore) == address(0) || gateway == address(0)
                    || address(marketCore) != address(policyCore)
                    || marketCore.portfolioController() != address(coordinator)
            ) revert InvalidCustodyTopology();

            ClaimantRegistry roster = OrderBookCore(address(marketCore)).claimantRegistry();
            if (address(roster) == address(0) || roster.registrar() != address(marketCore)) {
                revert InvalidCustodyTopology();
            }
        }
    }
}

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
            _verifyMarket(coordinator, policy, vault, i);
        }
    }
    function _verifyMarket(
        PortfolioAdmissionCoordinator coordinator,
        PortfolioMarginPolicy policy,
        PortfolioCollateralVault vault,
        uint256 index
    ) internal view {
        (IOrderBookCore marketCore, address gateway) = coordinator.markets(index);
        (IOrderBookCore policyCore,,,) = policy.markets(index);
        if (address(marketCore) == address(0) || gateway == address(0)
            || address(marketCore) != address(policyCore)
            || marketCore.portfolioController() != address(coordinator)) {
            revert InvalidCustodyTopology();
        }
        OrderBookCore core = OrderBookCore(address(marketCore));
        if (core.collateralAsset() != address(vault.collateralToken())
            || core.advancedModule() != gateway) revert InvalidCustodyTopology();
        ClaimantRegistry roster = core.claimantRegistry();
        if (address(roster) == address(0) || roster.registrar() != address(core)) {
            revert InvalidCustodyTopology();
        }
    }

}

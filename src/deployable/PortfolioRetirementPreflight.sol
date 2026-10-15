// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {PortfolioMarginPolicy} from "./PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "./PortfolioCollateralVault.sol";
import {PortfolioAdmissionCoordinator} from "./PortfolioAdmissionCoordinator.sol";

interface IRetirementCollateralAsset {
    function collateralToken() external view returns (address);
}
interface IRetirementMarketReserves {
    function protocolFeesAccrued() external view returns (uint256);
    function insuranceReserves() external view returns (uint256);
}
interface IRetirementAdvancedInventory {
    function activeInsuranceBlockingOrders(address account) external view returns (bool);
}

/// @notice Strict preflight for operator-enumerated accounts, NOT a migration
/// executor or an exhaustive on-chain registry of all historical claimants.
/// No migration is authorized by a successful call to this contract.
contract PortfolioRetirementPreflight {
    error UnsafeRetirement();

    PortfolioAdmissionCoordinator public immutable coordinator;
    PortfolioMarginPolicy public immutable policy;
    PortfolioCollateralVault public immutable vault;

    constructor(address coordinator_) {
        if (coordinator_ == address(0)) revert UnsafeRetirement();
        coordinator = PortfolioAdmissionCoordinator(coordinator_);
        policy = PortfolioAdmissionCoordinator(coordinator_).policy();
        vault = PortfolioAdmissionCoordinator(coordinator_).vault();
    }

    function assertConfigurationAndReservesClear() external view {
        if (
            address(policy.sharedCollateralVault()) != address(vault)
                || vault.controller() != address(coordinator)
                || coordinator.marketCount() != policy.marketCount()
                || vault.totalAccountedCollateral() != 0
                || vault.collateralToken().balanceOf(address(vault)) != 0
        ) revert UnsafeRetirement();

        for (uint256 i; i < coordinator.marketCount(); ++i) {
            (IOrderBookCore core,) = coordinator.markets(i);
            (IOrderBookCore configured,,,) = policy.markets(i);
            if (address(core) != address(configured)
                || IRetirementCollateralAsset(address(core)).collateralToken()
                    != address(vault.collateralToken())
                || core.portfolioController() != address(coordinator)
                || IRetirementMarketReserves(address(core)).protocolFeesAccrued() != 0
                || IRetirementMarketReserves(address(core)).insuranceReserves() != 0
            ) revert UnsafeRetirement();
        }
    }

    function assertAccountsClear(address[] calldata accounts) external view {
        if (accounts.length == 0) revert UnsafeRetirement();
        address prior;
        for (uint256 a; a < accounts.length; ++a) {
            address account = accounts[a];
            // Sorted strictly ascending: no zero address or duplicate padding.
            if (account <= prior) revert UnsafeRetirement();
            prior = account;
            if (
                vault.balanceOf(account) != 0
                    || vault.portfolioWithdrawn(account) != 0
                    || vault.lockedCollateral(account) != 0
                    || vault.collateralClaim(account) != 0
            ) revert UnsafeRetirement();

            for (uint256 i; i < coordinator.marketCount(); ++i) {
                (IOrderBookCore core, address gateway) = coordinator.markets(i);
                (int80 position, int80 minimum, int80 maximum) = core.accountRisk(account);
                if (position != 0 || minimum != 0 || maximum != 0
                    || core.accountMarketValue(account) != 0
                    || core.activeQuoteCount(account) != 0
                    || IRetirementAdvancedInventory(gateway).activeInsuranceBlockingOrders(account)
                ) revert UnsafeRetirement();
            }
        }
    }
}

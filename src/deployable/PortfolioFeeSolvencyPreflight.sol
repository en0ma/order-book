// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioAdmissionCoordinator} from "./PortfolioAdmissionCoordinator.sol";
import {PortfolioCollateralVault} from "./PortfolioCollateralVault.sol";
import {PortfolioClaimantTopology} from "./PortfolioClaimantTopology.sol";
import {ClaimantRegistry} from "./ClaimantRegistry.sol";
import {OrderBookCore} from "./OrderBookCore.sol";
import {IOrderBookCore} from "./IOrderBookCore.sol";

interface IPortfolioActiveOrders {
    function activeAdvancedOrders(address account) external view returns (uint32);
}

/// @notice Conservative, bounded fee backing proof for a completely settled
/// portfolio book. Read-only: it cannot authorize an ERC20 withdrawal.
/// @dev Every Core/vault claimant comes from a contract-owned immutable registry;
/// no caller-supplied or off-chain address list can make the proof pass.
contract PortfolioFeeSolvencyPreflight {
    error TooManyClaimants();
    error UnsettledExposure();

    uint256 public constant MAX_RAW_CLAIMANTS = 64;
    uint256 public constant MAX_MARKET_CLAIMANT_PAIRS = 256;
    PortfolioClaimantTopology public immutable topology;

    constructor() {
        topology = new PortfolioClaimantTopology();
    }

    function conservativeCapacity(PortfolioAdmissionCoordinator coordinator)
        external
        view
        returns (uint256 capacity, uint256 positiveClaims, uint256 protectedLiabilities)
    {
        (uint256 marketCount, uint256 vaultCount) = topology.verifyTopology(coordinator);
        uint256 rawCount = vaultCount;
        for (uint256 market; market < marketCount; ++market) {
            (IOrderBookCore marketCore,) = coordinator.markets(market);
            rawCount += OrderBookCore(address(marketCore)).claimantRegistry().count();
        }

        // Fail closed before any array allocation or unbounded nested calls.
        if (rawCount > MAX_RAW_CLAIMANTS
            || rawCount * marketCount > MAX_MARKET_CLAIMANT_PAIRS) {
            revert TooManyClaimants();
        }

        address[] memory discovered = new address[](rawCount);
        uint256 uniqueCount = _collectUnion(coordinator, marketCount, discovered);

        PortfolioCollateralVault vault = coordinator.vault();
        for (uint256 i; i < uniqueCount; ++i) {
            positiveClaims += _positiveFlatPortfolioClaim(
                coordinator, vault, marketCount, discovered[i]
            );
        }

        protectedLiabilities = positiveClaims;
        uint256 accrued;
        for (uint256 market; market < marketCount; ++market) {
            (IOrderBookCore marketCore,) = coordinator.markets(market);
            OrderBookCore core = OrderBookCore(address(marketCore));
            if (core.riskIncreasePaused()
                || core.claimantRegistry().pendingMakerUnattributedLots() != 0
                || core.claimantRegistry().pendingPriceLevelCount() != 0) {
                revert UnsettledExposure();
            }
            protectedLiabilities += core.insuranceReserves()
                + core.pendingMakerRebateReserve();
            accrued += core.protocolFeesAccrued();
        }

        uint256 custody = vault.collateralToken().balanceOf(address(vault));
        if (custody <= protectedLiabilities) return (0, positiveClaims, protectedLiabilities);
        uint256 unencumbered = custody - protectedLiabilities;
        capacity = accrued < unencumbered ? accrued : unencumbered;
    }

    function _collectUnion(
        PortfolioAdmissionCoordinator coordinator,
        uint256 marketCount,
        address[] memory discovered
    ) internal view returns (uint256 length) {
        ClaimantRegistry roster = coordinator.vault().custodyClaimantRegistry();
        uint256 count = roster.count();
        for (uint256 i; i < count; ++i) {
            length = _addUnique(discovered, length, roster.at(i));
        }
        for (uint256 market; market < marketCount; ++market) {
            (IOrderBookCore marketCore,) = coordinator.markets(market);
            roster = OrderBookCore(address(marketCore)).claimantRegistry();
            count = roster.count();
            for (uint256 i; i < count; ++i) {
                length = _addUnique(discovered, length, roster.at(i));
            }
        }
    }

    function _addUnique(address[] memory accounts, uint256 length, address account)
        internal pure returns (uint256)
    {
        for (uint256 i; i < length; ++i) {
            if (accounts[i] == account) return length;
        }
        accounts[length] = account;
        return length + 1;
    }

    function _positiveFlatPortfolioClaim(
        PortfolioAdmissionCoordinator coordinator,
        PortfolioCollateralVault vault,
        uint256 marketCount,
        address account
    ) internal view returns (uint256) {
        if (vault.lockedCollateral(account) != 0) revert UnsettledExposure();
        for (uint256 market; market < marketCount; ++market) {
            (IOrderBookCore core, address gateway) = coordinator.markets(market);
            (int80 position, int80 minPosition, int80 maxPosition) =
                core.accountRisk(account);
            if (position != 0 || minPosition != 0 || maxPosition != 0
                || core.activeQuoteCount(account) != 0
                || IPortfolioActiveOrders(gateway).activeAdvancedOrders(account) != 0) {
                revert UnsettledExposure();
            }
        }
        int256 claim = coordinator.settledCashEquity(account);
        return claim > 0 ? uint256(claim) : 0;
    }
}

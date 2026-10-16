// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioTwoMarketFeeIsolationTest} from "./PortfolioTwoMarketFeeIsolation.t.sol";
import {PortfolioClaimantTopology} from "../src/deployable/PortfolioClaimantTopology.sol";
import {StandaloneFeeSolvencyPreflight} from "../src/deployable/StandaloneFeeSolvencyPreflight.sol";
import {PortfolioAdmissionCoordinator} from "../src/deployable/PortfolioAdmissionCoordinator.sol";

contract Issue203PortfolioTopologyTest is PortfolioTwoMarketFeeIsolationTest {
    function test_TwoMarketControllerVaultPolicyAndClaimantsAreAuthenticated() public {
        PortfolioClaimantTopology proof = new PortfolioClaimantTopology();
        (uint256 marketCount, uint256 vaultClaimants) = proof.verifyTopology(coordinator);
        assertEq(marketCount, 2, "policy/coordinator market count mismatch");
        assertEq(vaultClaimants, 2, "custody claimant registry not bound to vault");
        assertTrue(
            vault.custodyClaimantRegistry().registrar() == address(vault),
            "vault registry has forged registrar"
        );
        assertTrue(
            core0.claimantRegistry().registrar() == address(core0),
            "first market registry has forged registrar"
        );
        assertTrue(
            core1.claimantRegistry().registrar() == address(core1),
            "second market registry has forged registrar"
        );
    }

    function test_ForgedCoordinatorCannotCertifyExistingSharedVault() public {
        PortfolioAdmissionCoordinator.MarketInput[] memory markets =
            new PortfolioAdmissionCoordinator.MarketInput[](2);
        markets[0] = PortfolioAdmissionCoordinator.MarketInput(address(core0), address(gateway0));
        markets[1] = PortfolioAdmissionCoordinator.MarketInput(address(core1), address(gateway1));

        PortfolioAdmissionCoordinator forged = new PortfolioAdmissionCoordinator(
            address(policy), address(vault), markets
        );
        PortfolioClaimantTopology proof = new PortfolioClaimantTopology();

        (bool accepted,) = address(proof).call(
            abi.encodeCall(proof.verifyTopology, (forged))
        );
        assertTrue(!accepted, "forged market coordinator accepted as vault authority");
    }
    function test_StandaloneFeeProofRejectsBothPortfolioMarketCores() public {
        StandaloneFeeSolvencyPreflight proof = new StandaloneFeeSolvencyPreflight();
        (bool accepted0,) = address(proof).call(
            abi.encodeCall(proof.conservativeCapacity, (core0))
        );
        (bool accepted1,) = address(proof).call(
            abi.encodeCall(proof.conservativeCapacity, (core1))
        );
        assertTrue(!accepted0 && !accepted1, "market Core treated vault custody as local backing");
    }

}

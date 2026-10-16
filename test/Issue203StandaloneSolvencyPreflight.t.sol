// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Issue203ClaimantRegistryTest} from "./Issue203ClaimantRegistry.t.sol";
import {StandaloneFeeSolvencyPreflight} from "../src/deployable/StandaloneFeeSolvencyPreflight.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

contract Issue203StandaloneSolvencyPreflightTest is Issue203ClaimantRegistryTest {
    StandaloneFeeSolvencyPreflight internal proof;

    function setUp() public override {
        super.setUp();
        proof = new StandaloneFeeSolvencyPreflight();
    }

    function test_EnumeratesActualOnChainClaimsAndCanonicalTokenCustody() public {
        (uint256 capacity, uint256 claims, uint256 reserved) =
            proof.conservativeCapacity(core);
        assertEq(capacity, 0, "unearned fees became distributable");
        assertEq(claims, 100000, "missing user collateral claim");
        assertEq(reserved, 100000, "incorrect protected backing");

        token.mint(address(core), 1000);
        (capacity, claims, reserved) = proof.conservativeCapacity(core);
        assertEq(capacity, 0, "donated collateral manufactured protocol fees");
        assertEq(claims, 100000, "donation changed depositor liabilities");
        assertEq(reserved, 100000, "donation changed reserve accounting");
    }

    function test_FailsClosedOnOpenMakerRiskEvenWithExcessTokens() public {
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        token.mint(address(core), 1000000);

        (bool verified,) = address(proof).call(
            abi.encodeCall(proof.conservativeCapacity, (core))
        );
        assertTrue(!verified, "active maker exposure was treated as free surplus");
    }

    function test_RejectsClaimantSetThatExceedsBoundedGasBudget() public {
        for (uint256 i; i < 65; ++i) {
            address account = address(uint160(i + 1000));
            token.mint(account, 1);
            vm.prank(account);
            token.approve(address(core), 1);
            vm.prank(account);
            core.depositCollateral(1);
        }

        assertEq(core.claimantRegistry().count(), 67, "claimant inventory was truncated");
        (bool verified,) = address(proof).call(
            abi.encodeCall(proof.conservativeCapacity, (core))
        );
        assertTrue(!verified, "unbounded claimant scan was accepted");
    }
}

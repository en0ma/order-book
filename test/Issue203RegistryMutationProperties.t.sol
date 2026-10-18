// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ClaimantRegistry} from "../src/deployable/ClaimantRegistry.sol";

/// @notice Property tests for the independently authenticated on-chain
/// claimant universe. Registry completeness must not trust operator lists.
contract Issue203RegistryMutationPropertiesTest is TestBase {
    ClaimantRegistry internal roster;

    function setUp() public {
        roster = new ClaimantRegistry();
    }

    function testFuzz_UniqueFirstSeenClaimants(uint160 aSeed, uint160 bSeed) public {
        address a = address(aSeed == 0 ? uint160(1) : aSeed);
        address b = address(bSeed == 0 ? uint160(2) : bSeed);
        roster.record(a);
        roster.record(a);
        assertEq(roster.count(), 1, "duplicate account minted a second liability slot");
        assertTrue(roster.at(0) == a, "first account was reordered");
        assertTrue(roster.contains(a), "original claimant membership lost");

        roster.record(b);
        uint256 expectedCount = a == b ? 1 : 2;
        assertEq(roster.count(), expectedCount, "second account deduplication incorrect");
        if (a != b) assertTrue(roster.at(1) == b, "second account index incorrect");
        assertTrue(roster.contains(b), "second account was not recorded");
    }

    function testFuzz_OnlyImmutableRegistrarMayRegister(address outsider, address claimant) public {
        if (outsider == address(this)) outsider = address(0xBADD);
        if (claimant == address(0)) claimant = address(0xC0DE);

        vm.prank(outsider);
        (bool forged,) = address(roster).call(
            abi.encodeWithSignature("record(address)", claimant)
        );
        assertTrue(!forged, "external operator forged a claimant");
        assertEq(roster.count(), 0, "forged registry record changed membership");

        (bool zero,) = address(roster).call(
            abi.encodeWithSignature("record(address)", address(0))
        );
        assertTrue(!zero, "zero-account claimant was admitted");
        assertEq(roster.count(), 0, "invalid claimant polluted registry");
    }
}

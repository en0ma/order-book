// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {BoundedFundingUpdater} from "../src/deployable/BoundedFundingUpdater.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract BoundedFundingUpdaterTest is TestBase {
    OrderBookCore core;
    BoundedFundingUpdater updater;
    address constant OPERATOR = address(0xB0B);

    function setUp() public {
        core = new OrderBookCore(address(new MockERC20()), address(new MockMarkOracle(100)), 30, 1000, 0, 0);
        updater = new BoundedFundingUpdater(address(core), OPERATOR, 3600, 5e16);
        core.setFundingUpdater(address(updater));
    }

    function testRejectsEarlyUpdatesAndUnauthorizedCallers() public {
        vm.prank(OPERATOR);
        (bool early,) = address(updater).call(abi.encodeCall(updater.publish, (int128(1))));
        assertTrue(!early, "published before interval");
        vm.warp(block.timestamp + 3600);
        (bool unauthorized,) = address(updater).call(abi.encodeCall(updater.publish, (int128(1))));
        assertTrue(!unauthorized, "unauthorized updater accepted");
        vm.prank(OPERATOR);
        updater.publish(1);
        assertEq(int256(updater.lastIndexX18()), 1, "funding not published");
    }

    function testOperatorCanForwardEmergencyPauseButCannotUnpause() public {
        vm.prank(OPERATOR);
        updater.pauseRiskIncrease();
        assertTrue(core.riskIncreasePaused(), "operator pause did not reach Core");
        core.setRiskIncreasePaused(false);
        (bool unauthorized,) = address(updater).call(abi.encodeCall(updater.pauseRiskIncrease, ()));
        assertTrue(!unauthorized, "unauthorized caller invoked emergency pause");
        assertTrue(!core.riskIncreasePaused(), "wrapper bypassed owner unpause");
    }

    function testIndependentRiskGuardianCanOnlyPauseAndCanBeRevoked() public {
        address guardian = address(0xCAFE);
        vm.prank(OPERATOR);
        updater.setRiskOffGuardian(guardian);
        assertEq(uint256(uint160(updater.riskOffGuardian())), uint256(uint160(guardian)), "guardian not assigned");

        vm.prank(guardian);
        (bool funding,) = address(updater).call(abi.encodeCall(updater.publish, (int128(1))));
        assertTrue(!funding, "guardian published funding");
        vm.prank(guardian);
        updater.pauseRiskIncrease();
        assertTrue(core.riskIncreasePaused(), "guardian pause not forwarded");

        vm.prank(guardian);
        (bool change,) = address(updater).call(abi.encodeCall(updater.setRiskOffGuardian, (address(0))));
        assertTrue(!change, "guardian revoked its own role");

        core.setRiskIncreasePaused(false);
        vm.prank(OPERATOR);
        updater.setRiskOffGuardian(address(0));
        vm.prank(guardian);
        (bool again,) = address(updater).call(abi.encodeCall(updater.pauseRiskIncrease, ()));
        assertTrue(!again, "revoked guardian retained pause authority");
        assertTrue(!core.riskIncreasePaused(), "revoked guardian paused Core");

        vm.prank(address(0xBAD));
        (bool unauthorized,) = address(updater).call(
            abi.encodeCall(updater.setRiskOffGuardian, (guardian))
        );
        assertTrue(!unauthorized, "untrusted caller configured guardian");
    }

    function testRejectsLargePositiveAndNegativeIndexMoves() public {
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        (bool bigPositive,) = address(updater).call(abi.encodeCall(updater.publish, (int128(5e16 + 1))));
        assertTrue(!bigPositive, "oversized positive funding accepted");
        vm.prank(OPERATOR);
        (bool bigNegative,) = address(updater).call(abi.encodeCall(updater.publish, (int128(-5e16 - 1))));
        assertTrue(!bigNegative, "oversized negative funding accepted");
        vm.prank(OPERATOR);
        updater.publish(int128(-5e16));
        assertEq(int256(updater.lastIndexX18()), -5e16, "negative funding rejected");
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        updater.publish(0);
        assertEq(int256(updater.lastIndexX18()), 0, "symmetric recovery rejected");
    }

    function testAuthorityRotationCanBypassWrapperTracking() public {
        core.setFundingUpdater(address(this));
        core.setFundingIndex(1);
        core.setFundingUpdater(address(updater));
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        (bool accepted,) = address(updater).call(abi.encodeCall(updater.publish, (int128(2))));
        assertTrue(!accepted, "rotated Core funding bypassed wrapper accounting");
        assertEq(int256(updater.lastIndexX18()), 0, "rejected publication changed wrapper");
        assertEq(int256(core.currentFundingIndexX18()), 1, "Core index changed after rejected publication");
    }

    function testAuthorityDriftFailsClosedUntilGovernanceRestoresCheckpoint() public {
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        updater.publish(5);
        core.setFundingUpdater(address(this));
        core.setFundingIndex(9);
        core.setFundingUpdater(address(updater));
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        (bool ok,) = address(updater).call(abi.encodeCall(updater.publish, (int128(10))));
        assertTrue(!ok, "drifted index accepted");
        assertEq(int256(updater.lastIndexX18()), 5, "wrapper checkpoint mutated");
        // Governance must explicitly restore the last verified index before
        // the operator may resume bounded publication.
        core.setFundingUpdater(address(this));
        core.setFundingIndex(5);
        core.setFundingUpdater(address(updater));
        vm.prank(OPERATOR);
        updater.publish(10);
        assertEq(int256(core.currentFundingIndexX18()), 10, "restored publication failed");
    }

    function testActiveAuthorityRotationBlocksPublication() public {
        core.setFundingUpdater(address(this));
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        (bool ok,) = address(updater).call(abi.encodeCall(updater.publish, (int128(1))));
        assertTrue(!ok, "inactive funding authority published");
        assertEq(int256(updater.lastIndexX18()), 0, "inactive publication changed state");
    }

    function testFuzz_NoMoveAboveAbsoluteCap(uint128 randomDelta) public {
        uint256 absDelta = uint256(randomDelta) % 1e17;
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        (bool success,) = address(updater).call(
            abi.encodeCall(updater.publish, (int128(int256(absDelta))))
        );
        assertTrue(success == (absDelta <= 5e16), "funding delta bound violated");
    }
}

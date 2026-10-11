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
        assertEq(int256(core.fundingIndexX18Value()), 1, "funding not published");
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
        assertEq(int256(core.fundingIndexX18Value()), -5e16, "negative funding rejected");
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        updater.publish(0);
        assertEq(int256(core.fundingIndexX18Value()), 0, "symmetric recovery rejected");
    }

    function testDetectsUnexpectedExternalIndexChanges() public {
        core.setFundingUpdater(address(this));
        core.setFundingIndex(1);
        core.setFundingUpdater(address(updater));
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        (bool accepted,) = address(updater).call(abi.encodeCall(updater.publish, (int128(2))));
        assertTrue(!accepted, "external index override went unnoticed");
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

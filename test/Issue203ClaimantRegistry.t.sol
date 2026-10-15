// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract Issue203ClaimantRegistryTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);

    MockERC20 internal token;
    OrderBookCore internal core;

    function setUp() public {
        token = new MockERC20();
        core = new OrderBookCore(address(token), address(new MockMarkOracle(100)), 30, 1000, 100, 0);
        token.mint(MAKER, 100000);
        token.mint(TAKER, 100000);
        vm.prank(MAKER);
        token.approve(address(core), type(uint256).max);
        vm.prank(MAKER);
        core.depositCollateral(50000);
        vm.prank(TAKER);
        token.approve(address(core), type(uint256).max);
        vm.prank(TAKER);
        core.depositCollateral(50000);
    }

    function test_MonotoneUniqueClaimantsThroughMakerAndTakerMutations() public {
        assertEq(core.claimantRegistry().count(), 2, "initial deposit claimants missing");
        assertTrue(core.claimantRegistry().at(0) == MAKER, "wrong maker claimant");
        assertTrue(core.claimantRegistry().at(1) == TAKER, "wrong taker claimant");

        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);
        assertEq(core.claimantRegistry().count(), 2, "duplicate claimant after settlement");
        assertTrue(core.claimantRegistry().at(0) == MAKER, "maker reordered");
        assertTrue(core.claimantRegistry().at(1) == TAKER, "taker reordered");
    }

    function testFuzz_DuplicateDepositsDoNotIncreaseRoster(uint96 amountSeed) public {
        uint256 amount = uint256(amountSeed) % 1000 + 1;
        vm.prank(MAKER);
        core.depositCollateral(amount);
        assertEq(core.claimantRegistry().count(), 2, "duplicate deposit created claimant");
    }

    function test_NewAccountAddsExactlyOneClaimant() public {
        address newcomer = address(0xCAFE);
        token.mint(newcomer, 1000);
        vm.prank(newcomer);
        token.approve(address(core), 1000);
        vm.prank(newcomer);
        core.depositCollateral(1000);
        vm.prank(newcomer);
        core.withdrawCollateral(1000);
        assertEq(core.claimantRegistry().count(), 3, "withdrawal deleted historic claimant");
        assertTrue(core.claimantRegistry().at(2) == newcomer, "claimant address incorrect");
    }
}

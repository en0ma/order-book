// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Protocol fee allocation must not consume a lazy maker rebate claim.
/// @dev Rebate reserve is the upper half of Core's fee accounting packed word.
contract LazyMakerRebateReserveAllocationTest is TestBase {
    address internal constant MAKER = address(0xB0B);
    address internal constant TAKER = address(0xA11CE);
    MockERC20 internal token;
    OrderBookCoreHarness internal core;

    function setUp() public {
        token = new MockERC20();
        SegmentTreeExtremaOracle mark =
            new SegmentTreeExtremaOracle(address(this), 100, 3600);
        // 100 bps taker fee, 50 bps maker rebate: 100 and 50 at notional 10_000.
        core = new OrderBookCoreHarness(address(token), address(mark), 30, 1000, 100, 50);
        _fund(MAKER, 20000);
        _fund(TAKER, 20000);
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        assertEq(
            uint256(core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC)),
            100,
            "taker failed to consume maker quote"
        );
        // Maker has not settled its lazy fill.
        assertEq(core.protocolFeesAccrued(), 50, "protocol fee was not net of reserved rebate");
    }

    function testAllocateAllProtocolFeesThenLazyMakerStillReceivesFullRebate() public {
        uint256 custody = token.balanceOf(address(core));
        (uint256 collateralBefore, int256 tradeBefore,,,) = core.accountingStateTest(MAKER);
        assertEq(tradeBefore, 0, "maker unexpectedly already settled");

        core.allocateProtocolFeesToInsurance(50);
        assertEq(core.protocolFeesAccrued(), 0, "protocol fees not allocated");
        assertEq(core.insuranceReserves(), 50, "insurance did not receive allocation");
        assertEq(token.balanceOf(address(core)), custody, "allocation transferred tokens");

        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);
        (uint256 collateralAfter, int256 tradeAfter,,,) = core.accountingStateTest(MAKER);
        assertEq(collateralAfter, collateralBefore, "maker deposit changed");
        assertEq(tradeAfter, 10050, "lazy maker cashflow missed reserved 50 rebate");
        assertEq(core.protocolFeesAccrued(), 0, "maker settlement recreated fee reserve");
        assertEq(core.insuranceReserves(), 50, "maker settlement consumed insurance");
        assertEq(token.balanceOf(address(core)), custody, "maker settlement moved custody");
    }

    function testCannotAllocateMakerRebateReserveAsProtocolFee() public {
        uint256 custody = token.balanceOf(address(core));
        (bool over,) = address(core).call(
            abi.encodeCall(core.allocateProtocolFeesToInsurance, (uint256(100)))
        );
        assertTrue(!over, "allocated fee inclusive of unmaterialized maker rebate");
        assertEq(core.protocolFeesAccrued(), 50, "over-allocation spent protocol fees");
        assertEq(core.insuranceReserves(), 0, "over-allocation spent reserved rebates");
        assertEq(token.balanceOf(address(core)), custody, "over-allocation moved custody");

        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);
        (, int256 tradeAfter,,,) = core.accountingStateTest(MAKER);
        assertEq(tradeAfter, 10050, "failed over-allocation damaged maker rebate");
    }

    function _fund(address actor, uint256 amount) internal {
        token.mint(actor, amount);
        vm.prank(actor);
        token.approve(address(core), amount);
        vm.prank(actor);
        core.depositCollateral(amount);
    }
}

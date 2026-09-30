// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract AdvancedOrderModuleTest is TestBase {
    OrderBookCore internal core;
    AdvancedOrderModule internal module;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100);
        core = new OrderBookCore();
        module = new AdvancedOrderModule(address(core), address(oracle));

        core.configureSettlement(address(token), address(oracle));
        core.configureRisk(100, 40, 1_000);
        core.configureAdvancedModule(address(module));

        _fund(ALICE, 1_000_000);
        _fund(BOB, 1_000_000);
        _fund(CAROL, 1_000_000);
        _fund(address(this), 1_000_000);
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }

    function testModuleConditionalExecutesAgainstCore() public {
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 100);

        vm.prank(ALICE);
        uint64 orderId = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            110,
            40,
            IOrderBookCore.FillPolicy.IOC,
            false
        );

        uint96 filled = module.executeConditionalOrder(orderId);
        assertEq(filled, 40, "module conditional fill");
        assertEq(int256(core.accountPosition(ALICE)), 40, "module owner position");
    }

    function testModuleTriggeredLimitBracketResizesFromLaterMakerFills() public {
        vm.prank(ALICE);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            103,
            100
        );

        vm.prank(ALICE);
        uint64 tp = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            105,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        uint64 sl = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            false,
            90,
            80,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        module.linkOCO(tp, sl);
        vm.prank(ALICE);
        module.linkOTO(parent, tp);
        vm.prank(ALICE);
        module.linkOTO(parent, sl);

        uint96 immediate = module.executeConditionalOrder(parent);
        assertEq(immediate, 0, "entry should rest");

        vm.prank(BOB);
        core.take(IOrderBookCore.Side.Ask, 103, 40, IOrderBookCore.FillPolicy.IOC);

        module.syncRestingOrder(parent);

        (, uint96 tpLots,,,,,,,) = module.conditionalOrders(tp);
        (, uint96 slLots,,,,,,,) = module.conditionalOrders(sl);
        assertEq(tpLots, 40, "TP first lazy size");
        assertEq(slLots, 40, "SL first lazy size");

        vm.prank(BOB);
        core.take(IOrderBookCore.Side.Ask, 103, 30, IOrderBookCore.FillPolicy.IOC);

        module.syncRestingOrder(parent);

        (, tpLots,,,,,,,) = module.conditionalOrders(tp);
        (, slLots,,,,,,,) = module.conditionalOrders(sl);
        assertEq(tpLots, 70, "TP second lazy size");
        assertEq(slLots, 70, "SL second lazy size");

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 110, 70);

        oracle.record(110);

        uint96 exited = module.executeConditionalOrder(tp);
        assertEq(exited, 70, "TP exit");
        assertEq(int256(core.accountPosition(ALICE)), 0, "bracket did not close");

        (uint128 locked,,) = core.quoteStateRaw(ALICE, IOrderBookCore.Side.Bid, 103);
        assertEq(uint256(locked), 0, "remaining entry not cancelled");
    }

    function testMultipleSameTickModuleRestingSlicesCancelIndependently() public {
        vm.prank(ALICE);
        uint64 first = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            30
        );

        vm.prank(ALICE);
        uint64 second = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            20
        );

        module.executeConditionalOrder(first);
        module.executeConditionalOrder(second);

        uint128 lockedBefore = core.moduleLockedShares(
            ALICE, IOrderBookCore.Side.Bid, 99
        );
        assertTrue(lockedBefore > 0, "no module shares locked");

        vm.prank(ALICE);
        uint96 removedFirst = module.cancelRestingOrder(first);
        assertEq(removedFirst, 30, "first slice cancellation");

        (, uint96 remaining,) = core.poolState(IOrderBookCore.Side.Bid, 99);
        assertEq(remaining, 20, "second slice was disturbed");

        vm.prank(ALICE);
        uint96 removedSecond = module.cancelRestingOrder(second);
        assertEq(removedSecond, 20, "second slice cancellation");

        (, remaining,) = core.poolState(IOrderBookCore.Side.Bid, 99);
        assertEq(remaining, 0, "same-tick slices not fully cleared");
    }

    function testModuleTrailingUsesSegmentTreeOracle() public {
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 60);

        vm.prank(ALICE);
        core.take(IOrderBookCore.Side.Bid, 100, 60, IOrderBookCore.FillPolicy.IOC);

        vm.prank(ALICE);
        uint64 trailingId = module.placeTrailingOrder(
            IOrderBookCore.Side.Ask,
            10,
            80,
            60,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        oracle.record(120);

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 109, 60);

        oracle.record(109);

        uint96 filled = module.executeTrailingOrder(trailingId);
        assertEq(filled, 60, "module trailing fill");
        assertEq(int256(core.accountPosition(ALICE)), 0, "module trailing did not close");
    }
}

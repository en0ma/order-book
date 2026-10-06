// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {ExecutionStrategyModule} from "../src/deployable/ExecutionStrategyModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract ExecutionStrategyModuleTest is TestBase {
    OrderBookCore internal core;
    AdvancedOrderModule internal advanced;
    ExecutionStrategyModule internal strategy;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCore(
            address(token),
            address(oracle),
            40,
            1_000,
            0,
            0
        );
        advanced = new AdvancedOrderModule(address(core), address(oracle));
        strategy = new ExecutionStrategyModule(address(core), address(advanced));

        core.configureAdvancedModule(address(advanced));
        advanced.configureExecutionStrategyModule(address(strategy));

        _fund(ALICE, 1_000_000);
        _fund(BOB, 1_000_000);
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }

    function testIcebergReplenishesAfterDisplayedSliceGenerationRollover() public {
        vm.prank(ALICE);
        uint64 id = strategy.placeIceberg(
            IOrderBookCore.Side.Bid,
            95,
            50,
            10
        );

        (, uint96 visibleBefore,) =
            core.pools(IOrderBookCore.Side.Bid, 95);
        assertEq(visibleBefore, 10, "initial display mismatch");
        assertEq(
            advanced.activeAdvancedOrders(ALICE),
            1,
            "strategy missing from advanced count"
        );

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            95,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        (uint96 newlyFilled, uint96 visibleAfter) = strategy.refreshIceberg(id);
        assertEq(newlyFilled, 10, "displayed fill not materialized");
        assertEq(visibleAfter, 10, "iceberg not replenished");

        (, uint96 poolVisible,) =
            core.pools(IOrderBookCore.Side.Bid, 95);
        assertEq(poolVisible, 10, "replenished slice missing");

        ExecutionStrategyModule.Strategy memory state = strategy.strategyState(id);
        assertEq(state.remainingLots, 40, "hidden remaining mismatch");
        assertTrue(state.active, "iceberg completed too early");
    }

    function testIcebergCancelClearsVisibleQuoteAndAdvancedCount() public {
        vm.prank(ALICE);
        uint64 id = strategy.placeIceberg(
            IOrderBookCore.Side.Ask,
            105,
            40,
            10
        );

        vm.prank(ALICE);
        strategy.cancelStrategy(id);

        (, uint96 remaining,) =
            core.pools(IOrderBookCore.Side.Ask, 105);
        assertEq(remaining, 0, "visible iceberg quote left behind");
        assertEq(
            advanced.activeAdvancedOrders(ALICE),
            0,
            "cancel left strategy active"
        );
    }

    function testTWAPExecutesTimedSlicesAndRetainsUnfilledRemainder() public {
        vm.warp(1_000);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 25);

        vm.prank(ALICE);
        uint64 id = strategy.placeTWAP(
            IOrderBookCore.Side.Bid,
            100,
            30,
            10,
            1_000,
            60,
            1_600
        );

        uint96 first = strategy.executeTWAPSlice(id);
        assertEq(first, 10, "first TWAP slice");
        ExecutionStrategyModule.Strategy memory afterFirst = strategy.strategyState(id);
        assertEq(afterFirst.remainingLots, 20, "TWAP remaining after first");
        assertEq(uint256(afterFirst.nextExecution), 1_060, "TWAP next execution");

        (bool earlyOk,) = address(strategy).call(
            abi.encodeCall(strategy.executeTWAPSlice, (id))
        );
        assertTrue(!earlyOk, "TWAP executed before interval");

        vm.warp(1_060);
        uint96 second = strategy.executeTWAPSlice(id);
        assertEq(second, 10, "second TWAP slice");

        vm.warp(1_120);
        uint96 third = strategy.executeTWAPSlice(id);
        assertEq(third, 5, "third TWAP slice should respect available liquidity");

        ExecutionStrategyModule.Strategy memory afterThird = strategy.strategyState(id);
        assertEq(afterThird.remainingLots, 5, "unfilled TWAP remainder lost");
        assertTrue(afterThird.active, "partially filled TWAP completed");
    }

    function testPeggedOrderRepricesWithoutChangingRemainingSize() public {
        vm.prank(ALICE);
        uint64 id = strategy.placePegged(
            IOrderBookCore.Side.Bid,
            -1,
            110,
            20
        );

        (, uint96 oldLots,) =
            core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(oldLots, 20, "initial pegged quote");

        oracle.record(103);
        (uint96 newlyFilled, uint16 nextTick) = strategy.syncPegged(id);

        assertEq(newlyFilled, 0, "reprice fabricated fill");
        assertEq(uint256(nextTick), 102, "wrong pegged target");

        (, uint96 oldRemaining,) =
            core.pools(IOrderBookCore.Side.Bid, 99);
        (, uint96 newRemaining,) =
            core.pools(IOrderBookCore.Side.Bid, 102);
        assertEq(oldRemaining, 0, "old peg tick not cleared");
        assertEq(newRemaining, 20, "new peg tick not populated");
    }

    function testPeggedBidHonorsMaximumPriceBound() public {
        oracle.record(120);

        vm.prank(ALICE);
        strategy.placePegged(
            IOrderBookCore.Side.Bid,
            5,
            110,
            7
        );

        (, uint96 atBound,) =
            core.pools(IOrderBookCore.Side.Bid, 110);
        assertEq(atBound, 7, "bid peg exceeded price bound");
    }
}

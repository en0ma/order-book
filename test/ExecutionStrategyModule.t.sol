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
    address internal constant CAROL = address(0xCA401);

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
        _fund(CAROL, 1_000_000);
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
            0,
            "strategy leaked into advanced module count"
        );
        assertEq(
            strategy.activeStrategyCount(ALICE),
            1,
            "strategy registry count mismatch"
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

        (uint96 remainingLots,, bool active) = strategy.strategyStatus(id);
        assertEq(remainingLots, 40, "hidden remaining mismatch");
        assertTrue(active, "iceberg completed too early");
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
        (uint96 remainingAfterFirst, uint64 nextExecution,) =
            strategy.strategyStatus(id);
        assertEq(remainingAfterFirst, 20, "TWAP remaining after first");
        assertEq(uint256(nextExecution), 1_060, "TWAP next execution");

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

        (uint96 remainingAfterThird,, bool activeAfterThird) =
            strategy.strategyStatus(id);
        assertEq(remainingAfterThird, 5, "unfilled TWAP remainder lost");
        assertTrue(activeAfterThird, "partially filled TWAP completed");
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

    function testPeggedRepriceAccountsBurnAttributedFill() public {
        vm.prank(ALICE);
        uint64 id = strategy.placePegged(
            IOrderBookCore.Side.Bid,
            -1,
            110,
            1
        );

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Bid, 99, 2);

        vm.prank(CAROL);
        core.take(
            IOrderBookCore.Side.Ask,
            99,
            1,
            IOrderBookCore.FillPolicy.IOC
        );

        oracle.record(103);
        (uint96 newlyFilled, uint16 nextTick) = strategy.syncPegged(id);

        assertEq(newlyFilled, 1, "burn-attributed fill not counted");
        assertEq(uint256(nextTick), 102, "wrong repriced tick");
        assertEq(int256(_position(ALICE)), 1, "maker fill not materialized");

        (, uint96 replacementLots,) =
            core.pools(IOrderBookCore.Side.Bid, 102);
        assertEq(replacementLots, 0, "completed peg was recreated");

        (uint96 remainingLots,, bool active) = strategy.strategyStatus(id);
        assertEq(remainingLots, 0, "completed peg retained quantity");
        assertTrue(!active, "completed peg remained active");
    }

    function testLiquidationCleanupCanForceCancelContaminatedStrategyQuote() public {
        vm.prank(ALICE);
        uint64 id = strategy.placeIceberg(
            IOrderBookCore.Side.Bid,
            95,
            20,
            10
        );

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 5);

        uint64[] memory ids = new uint64[](1);
        ids[0] = id;

        advanced.configureLiquidationModule(address(this));
        strategy.liquidationCleanup(ALICE, ids);

        assertEq(
            advanced.activeAdvancedOrders(ALICE),
            0,
            "contaminated strategy survived liquidation cleanup"
        );

        (, uint96 contaminatedRemaining,) =
            core.pools(IOrderBookCore.Side.Bid, 95);
        assertEq(
            contaminatedRemaining,
            15,
            "strategy cleanup should leave contaminated quote to liquidator"
        );

        advanced.liquidationForceCancelQuote(
            ALICE, IOrderBookCore.Side.Bid, 95
        );

        (, uint96 remaining,) =
            core.pools(IOrderBookCore.Side.Bid, 95);
        assertEq(remaining, 0, "generic liquidation cleanup could not clear quote");
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

    function _position(address account) internal view returns (int80 settled) {
        (settled,,) = core.accountRisk(account);
    }
}

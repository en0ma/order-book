// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract AdvancedOrderModuleTest is TestBase {
    OrderBookCore internal core;
    AdvancedOrderModule internal module;
    MarketMakerModule internal marketMaker;
    LiquidationModule internal liquidation;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCore(address(token), address(oracle), 40, 1_000);
        module = new AdvancedOrderModule(address(core), address(oracle));
        marketMaker = new MarketMakerModule(address(core), address(module));
        liquidation = new LiquidationModule(address(core), address(module), 500);

        core.configureAdvancedModule(address(module));
        module.configureMarketMakerModule(address(marketMaker));
        module.configureLiquidationModule(address(liquidation));

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

    function testModuleRejectsDifferentExtremaOracle() public {
        SegmentTreeExtremaOracle otherOracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);

        (bool ok,) = address(this).call(
            abi.encodeCall(
                this.deployAdvancedModuleForTest,
                (address(core), address(otherOracle))
            )
        );

        assertTrue(!ok, "module accepted a different trailing oracle");
    }

    function deployAdvancedModuleForTest(address core_, address oracle_)
        external
        returns (AdvancedOrderModule deployed)
    {
        deployed = new AdvancedOrderModule(core_, oracle_);
    }

    function testModuleMinimumFillIsAtomic() public {
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 40);

        vm.prank(ALICE);
        (bool ok,) = address(module).call(
            abi.encodeCall(
                module.takeMinFill,
                (
                    IOrderBookCore.Side.Bid,
                    uint16(100),
                    uint96(50),
                    uint96(45),
                    false
                )
            )
        );
        assertTrue(!ok, "minimum-fill should revert below threshold");

        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Ask, 100);
        assertEq(remaining, 40, "failed minimum-fill mutated maker liquidity");
        assertEq(int256(_corePosition(ALICE)), 0, "failed minimum-fill mutated position");

        vm.prank(ALICE);
        uint96 filled = module.takeMinFill(
            IOrderBookCore.Side.Bid,
            100,
            50,
            40,
            false
        );
        assertEq(filled, 40, "minimum-fill success quantity");
        assertEq(int256(_corePosition(ALICE)), 40, "minimum-fill position");
    }

    function testModuleReduceOnlyCannotReversePosition() public {
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 60);

        vm.prank(ALICE);
        core.take(IOrderBookCore.Side.Bid, 100, 60, IOrderBookCore.FillPolicy.IOC);
        assertEq(int256(_corePosition(ALICE)), 60, "long setup");

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 100);

        vm.prank(ALICE);
        uint96 closed = module.takeReduceOnly(
            IOrderBookCore.Side.Ask,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(closed, 60, "reduce-only did not cap at position");
        assertEq(int256(_corePosition(ALICE)), 0, "reduce-only crossed zero");
    }

    function testBatchReplaceQuotesCreatesUpdatesAndCancelsManagedSlices() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](3);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 95,
            lots: 30
        });
        updates[1] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 96,
            lots: 40
        });
        updates[2] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Ask,
            tick: 105,
            lots: 50
        });

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (, uint96 bid95,) = core.pools(IOrderBookCore.Side.Bid, 95);
        (, uint96 bid96,) = core.pools(IOrderBookCore.Side.Bid, 96);
        (, uint96 ask105,) = core.pools(IOrderBookCore.Side.Ask, 105);
        assertEq(bid95, 30, "bid95 create");
        assertEq(bid96, 40, "bid96 create");
        assertEq(ask105, 50, "ask105 create");

        updates[0].lots = 20;
        updates[1].lots = 0;
        updates[2].lots = 60;

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (, bid95,) = core.pools(IOrderBookCore.Side.Bid, 95);
        (, bid96,) = core.pools(IOrderBookCore.Side.Bid, 96);
        (, ask105,) = core.pools(IOrderBookCore.Side.Ask, 105);
        assertEq(bid95, 20, "bid95 replace");
        assertEq(bid96, 0, "bid96 cancel");
        assertEq(ask105, 60, "ask105 replace");
    }

    function testManagedQuoteReplaceAfterPartialFillSettlesThenRestoresTarget() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Ask,
            tick: 105,
            lots: 100
        });

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            40,
            IOrderBookCore.FillPolicy.IOC
        );

        updates[0].lots = 80;
        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Ask, 105);
        assertEq(remaining, 80, "managed quote target not restored");
        assertEq(int256(_corePosition(ALICE)), -40, "maker fill not settled on replace");
    }

    function testManagedQuoteCancelPreservesBracketSliceFillAtSameTick() public {
        vm.prank(ALICE);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            70
        );
        module.executeConditionalOrder(parent);

        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 99,
            lots: 30
        });
        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            99,
            50,
            IOrderBookCore.FillPolicy.IOC
        );

        updates[0].lots = 0;
        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint96 newlyFilled, uint96 cumulativeFilled) =
            module.syncRestingOrder(parent);

        assertEq(newlyFilled, 35, "bracket slice fill attribution changed");
        assertEq(cumulativeFilled, 35, "bracket cumulative fill changed");

        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(remaining, 35, "bracket remainder changed by MM cancellation");
    }

    function testStaleManagedCancelCannotTouchFreshOrdinaryQuote() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 95,
            lots: 25
        });

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            95,
            25,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(ALICE);
        uint128 freshShares =
            core.addLiquidity(IOrderBookCore.Side.Bid, 95, 15);

        updates[0].lots = 0;
        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint128 sharesAfter,,) =
            core.quotes(ALICE, IOrderBookCore.Side.Bid, 95);
        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Bid, 95);
        assertEq(uint256(sharesAfter), uint256(freshShares), "stale managed cancel touched fresh quote");
        assertEq(remaining, 15, "fresh ordinary quote removed");
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
        assertEq(int256(_corePosition(ALICE)), 40, "module owner position");
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
        assertEq(int256(_corePosition(ALICE)), 0, "bracket did not close");

        (uint128 locked,,) = core.quotes(ALICE, IOrderBookCore.Side.Bid, 103);
        assertEq(uint256(locked), 0, "remaining entry not cancelled");
    }

    function testStaleAdvancedLockCannotTouchFreshGenerationQuote() public {
        vm.prank(ALICE);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            30
        );

        module.executeConditionalOrder(parent);

        (,, uint32 oldGeneration) =
            core.pools(IOrderBookCore.Side.Bid, 99);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            99,
            30,
            IOrderBookCore.FillPolicy.IOC
        );

        (, uint96 depleted, uint32 depletedGeneration) =
            core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(depleted, 0, "advanced quote was not fully consumed");
        assertTrue(
            depletedGeneration != oldGeneration,
            "pool generation did not advance on depletion"
        );

        vm.prank(ALICE);
        uint128 freshShares =
            core.addLiquidity(IOrderBookCore.Side.Bid, 99, 20);

        (, uint96 freshRemaining, uint32 newGeneration) =
            core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(freshRemaining, 20, "fresh quote missing");
        assertTrue(newGeneration != oldGeneration, "pool generation did not advance");

        module.syncRestingOrder(parent);

        (uint128 sharesAfter,, uint32 quoteGeneration) =
            core.quotes(ALICE, IOrderBookCore.Side.Bid, 99);
        assertEq(uint256(sharesAfter), uint256(freshShares), "stale unlock touched fresh shares");
        assertEq(uint256(quoteGeneration), uint256(newGeneration), "fresh generation changed");
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

        vm.prank(ALICE);
        uint96 removedFirst = module.cancelRestingOrder(first);
        assertEq(removedFirst, 30, "first slice cancellation");

        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(remaining, 20, "second slice was disturbed");

        vm.prank(ALICE);
        uint96 removedSecond = module.cancelRestingOrder(second);
        assertEq(removedSecond, 20, "second slice cancellation");

        (, remaining,) = core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(remaining, 0, "same-tick slices not fully cleared");
    }

    function testLiquidationClearsManagedQuoteMetadataForRequote() public {
        address trader = address(0xDAD1);
        _fund(trader, 3_000);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(trader);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Ask,
            tick: 110,
            lots: 20
        });
        vm.prank(trader);
        marketMaker.batchReplaceQuotes(updates);

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 70, 100);
        oracle.record(70);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](1);
        sides[0] = IOrderBookCore.Side.Ask;
        uint16[] memory ticks = new uint16[](1);
        ticks[0] = 110;
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        liquidation.liquidate(trader, sides, ticks, conditionals, trailings);

        updates[0].tick = 90;
        updates[0].lots = 10;
        vm.prank(trader);
        marketMaker.batchReplaceQuotes(updates);

        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Ask, 90);
        assertEq(remaining, 10, "requote failed after liquidation cleanup");
    }

    function testModuleLiquidationCancelsTrailingAndClosesPosition() public {
        address trader = address(0xDAD);
        _fund(trader, 3_000);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(trader);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);

        vm.prank(trader);
        uint64 trailingId = module.placeTrailingOrder(
            IOrderBookCore.Side.Ask,
            10,
            50,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 70, 100);

        oracle.record(70);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](1);
        trailings[0] = trailingId;

        uint96 closed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings);

        assertEq(closed, 100, "module liquidation close");
        assertEq(int256(_corePosition(trader)), 0, "module liquidation position");
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
        assertEq(int256(_corePosition(ALICE)), 0, "module trailing did not close");
    }
    function _corePosition(address account) internal view returns (int80 position) {
        (position,,) = core.accountRisk(account);
    }

}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {AdvancedOrderModuleHarness} from "./harness/AdvancedOrderModuleHarness.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase, Vm} from "./TestBase.sol";

contract AdvancedOrderModuleTest is TestBase {
    OrderBookCoreHarness internal core;
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
        core =
            new OrderBookCoreHarness(address(token), address(oracle), 40, 1_000, 0, 0);
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

    function _fundOn(
        OrderBookCore target,
        MockERC20 targetToken,
        address account,
        uint256 amount
    ) internal {
        targetToken.mint(account, amount);
        vm.prank(account);
        targetToken.approve(address(target), type(uint256).max);
        vm.prank(account);
        target.depositCollateral(amount);
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

    function testConditionalFOKFailureRollsBackAdvancedAndCoreState() public {
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 40);

        vm.prank(ALICE);
        uint64 orderId = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            100,
            50,
            IOrderBookCore.FillPolicy.FOK,
            false
        );

        bytes32 advancedBefore = _conditionalFOKAdvancedState(orderId);
        bytes32 coreBefore = _conditionalFOKCoreState();

        (bool ok,) = address(module).call(
            abi.encodeCall(module.executeConditionalOrder, (orderId))
        );
        assertTrue(!ok, "insufficient conditional FOK unexpectedly succeeded");

        assertEq(
            uint256(_conditionalFOKAdvancedState(orderId)),
            uint256(advancedBefore),
            "failed FOK changed advanced state"
        );
        assertEq(
            uint256(_conditionalFOKCoreState()),
            uint256(coreBefore),
            "failed FOK changed core state"
        );

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);

        uint96 filled = module.executeConditionalOrder(orderId);
        assertEq(filled, 50, "restored conditional FOK did not execute");
        assertEq(
            module.activeAdvancedOrders(ALICE),
            0,
            "successful retry left conditional active"
        );
        assertEq(int256(_corePosition(ALICE)), 50, "successful FOK retry position mismatch");
    }

    function _conditionalFOKAdvancedState(uint64 orderId)
        internal
        view
        returns (bytes32)
    {
        (address ownerAfter,,,,,,,, uint8 flagsAfter) =
            module.conditionalOrders(orderId);
        return keccak256(
            abi.encode(
                ownerAfter,
                flagsAfter,
                module.activeAdvancedOrders(ALICE)
            )
        );
    }

    function _conditionalFOKCoreState() internal view returns (bytes32) {
        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(ALICE);
        (, uint256 reserved) = core.marginStateTest(ALICE);
        (, uint96 remaining, uint32 generation) =
            core.pools(IOrderBookCore.Side.Ask, 100);

        return keccak256(
            abi.encode(
                settled,
                minPosition,
                maxPosition,
                reserved,
                remaining,
                generation,
                core.protocolFeesAccrued()
            )
        );
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

    function testPackedManagedQuoteBatchMatchesTypedSemantics() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](3);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 94,
            lots: 50
        });
        updates[1] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 95,
            lots: 30
        });
        updates[2] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Ask,
            tick: 105,
            lots: 40
        });

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotesPacked(_packUpdates(updates));

        (, uint96 bid95,) = core.pools(IOrderBookCore.Side.Bid, 95);
        (, uint96 ask105,) = core.pools(IOrderBookCore.Side.Ask, 105);
        (, uint96 bid94,) = core.pools(IOrderBookCore.Side.Bid, 94);

        assertEq(bid95, 30, "packed bid95");
        assertEq(ask105, 40, "packed ask105");
        assertEq(bid94, 50, "packed bid94");

        updates[0].lots = 45;
        updates[1].lots = 35;
        updates[2].lots = 0;

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotesPacked(_packUpdates(updates));

        (, bid95,) = core.pools(IOrderBookCore.Side.Bid, 95);
        (, ask105,) = core.pools(IOrderBookCore.Side.Ask, 105);
        (, bid94,) = core.pools(IOrderBookCore.Side.Bid, 94);

        assertEq(bid95, 35, "packed increase");
        assertEq(ask105, 0, "packed cancel");
        assertEq(bid94, 45, "packed decrease");
    }

    function testManagedQuoteBatchRejectsDuplicateKeys() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](2);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 95,
            lots: 10
        });
        updates[1] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 95,
            lots: 20
        });

        vm.prank(ALICE);
        (bool ok,) = address(marketMaker).call(
            abi.encodeCall(marketMaker.batchReplaceQuotes, (updates))
        );

        assertTrue(!ok, "duplicate quote keys accepted");
    }

    function testPackedManagedQuoteBatchRejectsMalformedPayload() public {
        bytes memory malformed = new bytes(15);

        vm.prank(ALICE);
        (bool ok,) = address(marketMaker).call(
            abi.encodeCall(marketMaker.batchReplaceQuotesPacked, (malformed))
        );

        assertTrue(!ok, "malformed packed quote payload accepted");
    }

    function testPackedManagedQuoteBatchRejectsReservedBits() public {
        bytes memory malformed = bytes.concat(bytes16(uint128(1) << 127));

        vm.prank(ALICE);
        (bool ok,) = address(marketMaker).call(
            abi.encodeCall(marketMaker.batchReplaceQuotesPacked, (malformed))
        );

        assertTrue(!ok, "packed quote reserved bits accepted");
    }

    function testManagedQuoteTargetUsesCoreCeilClaimAtRoundingBoundary() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 95,
            lots: 1
        });

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint128 aliceSharesBefore,, uint32 generationBefore) =
            core.quotes(ALICE, IOrderBookCore.Side.Bid, 95);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 2);

        vm.prank(CAROL);
        core.take(
            IOrderBookCore.Side.Ask,
            95,
            1,
            IOrderBookCore.FillPolicy.IOC
        );

        (, uint96 remainingBefore,) =
            core.pools(IOrderBookCore.Side.Bid, 95);
        assertEq(remainingBefore, 2, "unexpected pre-refresh pool remainder");

        // Alice owns one third of the shares. After one of three lots is consumed,
        // her core claim is ceil(2/3) = 1. Refreshing to target 1 must therefore
        // be a no-op rather than adding another managed lot.
        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint128 aliceSharesAfter, uint96 aliceClaimAfter, uint32 generationAfter) =
            core.quotes(ALICE, IOrderBookCore.Side.Bid, 95);
        (, uint96 remainingAfter,) =
            core.pools(IOrderBookCore.Side.Bid, 95);

        assertEq(remainingAfter, 2, "managed refresh oversized pool at rounding boundary");
        assertEq(
            uint256(aliceSharesAfter),
            uint256(aliceSharesBefore),
            "managed refresh minted extra shares"
        );
        assertEq(aliceClaimAfter, 1, "managed maker claim drifted from target");
        assertEq(
            uint256(generationAfter),
            uint256(generationBefore),
            "managed refresh changed generation"
        );
        assertEq(int256(_corePosition(ALICE)), 0, "rounding-only consumption invented fill");
    }

    function testManagedQuoteCanCancelZeroFloorRedemptionSliceWithoutSyntheticFill() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 95,
            lots: 1
        });

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 2);

        vm.prank(CAROL);
        core.take(
            IOrderBookCore.Side.Ask,
            95,
            1,
            IOrderBookCore.FillPolicy.IOC
        );

        updates[0].lots = 0;
        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint128 aliceShares,,) =
            core.quotes(ALICE, IOrderBookCore.Side.Bid, 95);
        (, uint96 remaining,) =
            core.pools(IOrderBookCore.Side.Bid, 95);

        assertEq(uint256(aliceShares), 0, "zero-floor managed slice not cancelled");
        assertEq(remaining, 2, "zero-floor cancellation removed whole pool lot");

        vm.prank(BOB);
        core.settle(IOrderBookCore.Side.Bid, 95);
        assertEq(int256(_corePosition(BOB)), 0, "cancellation fabricated counterparty fill");

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(ALICE);
        assertEq(int256(settled), 1, "burn-exposed maker fill not materialized");
        assertEq(int256(minPosition), 1, "cancel left min reservation");
        assertEq(int256(maxPosition), 1, "cancel left max reservation");
    }

    function testManagedQuoteUnchangedTargetPreservesShareSlice() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Bid,
            tick: 95,
            lots: 50
        });

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint128 sharesBefore,, uint32 generationBefore) =
            core.quotes(ALICE, IOrderBookCore.Side.Bid, 95);

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint128 sharesAfter,, uint32 generationAfter) =
            core.quotes(ALICE, IOrderBookCore.Side.Bid, 95);

        assertEq(uint256(sharesAfter), uint256(sharesBefore), "unchanged target churned shares");
        assertEq(uint256(generationAfter), uint256(generationBefore), "unchanged target changed generation");
    }

    function testManagedQuoteIncreaseAddsOnlyDeltaWithoutGenerationReset() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Ask,
            tick: 105,
            lots: 100
        });

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint128 sharesBefore,, uint32 generationBefore) =
            core.quotes(ALICE, IOrderBookCore.Side.Ask, 105);

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

        (uint128 sharesAfter,, uint32 generationAfter) =
            core.quotes(ALICE, IOrderBookCore.Side.Ask, 105);
        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Ask, 105);

        assertEq(remaining, 80, "incremental target not restored");
        assertEq(uint256(generationAfter), uint256(generationBefore), "increase reset generation");
        assertTrue(sharesAfter > sharesBefore, "increase replaced instead of extending share slice");
        assertEq(int256(_corePosition(ALICE)), -40, "partial maker fill not settled");
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

    function testManagedQuoteSelfHealsAfterGenerationRolloverAndTickReopen() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Ask,
            tick: 105,
            lots: 10
        });

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (,, uint32 generation0) =
            core.pools(IOrderBookCore.Side.Ask, 105);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        (,, uint32 generation1) =
            core.pools(IOrderBookCore.Side.Ask, 105);
        assertEq(
            uint256(generation1),
            uint256(generation0 + 1),
            "full consumption did not roll generation"
        );

        // Reopen the same tick before ALICE refreshes the stale managed metadata.
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 7);

        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (, uint96 remaining, uint32 generationAfter) =
            core.pools(IOrderBookCore.Side.Ask, 105);
        (uint128 aliceShares, uint96 aliceClaim, uint32 aliceGeneration) =
            core.quotes(ALICE, IOrderBookCore.Side.Ask, 105);

        assertEq(remaining, 17, "rollover refresh did not add fresh managed target");
        assertTrue(aliceShares != 0, "rollover refresh left no fresh managed shares");
        assertEq(aliceClaim, 10, "fresh managed claim mismatch");
        assertEq(
            uint256(aliceGeneration),
            uint256(generationAfter),
            "managed quote remained on stale generation"
        );
        assertEq(
            uint256(generationAfter),
            uint256(generation1),
            "refresh unexpectedly rolled reopened generation"
        );
        assertEq(
            int256(_corePosition(ALICE)),
            -10,
            "stale generation maker fill was not settled before refresh"
        );

        // A second unchanged refresh must now be a strict no-op.
        uint128 sharesBefore = aliceShares;
        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint128 sharesAfter, uint96 claimAfter, uint32 generationFinal) =
            core.quotes(ALICE, IOrderBookCore.Side.Ask, 105);
        (, uint96 remainingAfter,) =
            core.pools(IOrderBookCore.Side.Ask, 105);

        assertEq(remainingAfter, 17, "stable refresh duplicated liquidity");
        assertEq(uint256(sharesAfter), uint256(sharesBefore), "stable refresh churned shares");
        assertEq(claimAfter, 10, "stable refresh changed claim");
        assertEq(
            uint256(generationFinal),
            uint256(generationAfter),
            "stable refresh changed generation"
        );
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

    function testUnfilledTriggeredLimitCancelRetiresDormantOTOChildren() public {
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
        assertEq(module.activeAdvancedOrders(ALICE), 3, "unexpected linked-order count");

        vm.prank(ALICE);
        uint96 removed = module.cancelRestingOrder(parent);

        assertEq(removed, 100, "unfilled parent cancellation mismatch");
        assertEq(module.activeAdvancedOrders(ALICE), 0, "dormant exits stranded after parent cancel");
        assertEq(core.activeQuoteCount(ALICE), 0, "parent core quote remained active");

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(ALICE);
        assertEq(int256(settled), 0, "unfilled parent changed settled position");
        assertEq(int256(minPosition), 0, "unfilled parent left min reservation");
        assertEq(int256(maxPosition), 0, "unfilled parent left max reservation");
    }

    function testPartialParentCancelPreservesActivatedExitOnly() public {
        vm.prank(ALICE);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            103,
            100
        );

        vm.prank(ALICE);
        uint64 exitId = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            105,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        module.linkOTO(parent, exitId);
        module.executeConditionalOrder(parent);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            103,
            40,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(ALICE);
        module.cancelRestingOrder(parent);

        assertEq(module.activeAdvancedOrders(ALICE), 1, "activated exit was not preserved");
        (, uint96 exitLots,,,,,,,) = module.conditionalOrders(exitId);
        assertEq(exitLots, 40, "activated exit lost realized sizing");

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 110, 40);
        oracle.record(110);

        uint96 exited = module.executeConditionalOrder(exitId);
        assertEq(exited, 40, "preserved exit failed");
        assertEq(module.activeAdvancedOrders(ALICE), 0, "exit lifecycle did not close");
        assertEq(int256(_corePosition(ALICE)), 0, "preserved exit did not flatten");
    }

    function testPartialTriggeredLimitCancelReleasesOnlyUnfilledReservation() public {
        vm.prank(ALICE);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            103,
            100
        );

        vm.prank(ALICE);
        uint64 exitId = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            105,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        module.linkOTO(parent, exitId);

        module.executeConditionalOrder(parent);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            103,
            40,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(ALICE);
        uint96 removed = module.cancelRestingOrder(parent);
        assertEq(removed, 60, "wrong unfilled parent cancellation");

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(ALICE);
        assertEq(int256(settled), 40, "filled parent position not materialized");
        assertEq(int256(minPosition), 40, "min envelope retained released reservation");
        assertEq(int256(maxPosition), 40, "max envelope retained released reservation");

        (, uint96 exitLots,,,,,,,) = module.conditionalOrders(exitId);
        assertEq(exitLots, 40, "OTO exit not sized to realized parent fill");
        assertEq(core.activeQuoteCount(ALICE), 0, "cancelled parent left active quote");
    }

    function testFullyConsumedTriggeredLimitSyncMaterializesBeforeBracketExit() public {
        vm.prank(ALICE);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            103,
            100
        );

        vm.prank(ALICE);
        uint64 exitId = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            105,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        module.linkOTO(parent, exitId);

        uint96 immediate = module.executeConditionalOrder(parent);
        assertEq(immediate, 0, "entry should rest");

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            103,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        module.syncRestingOrder(parent);

        assertEq(core.activeQuoteCount(ALICE), 0, "fully consumed parent remained unsettled");
        assertEq(int256(_corePosition(ALICE)), 100, "parent fill not materialized");

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 110, 100);
        oracle.record(110);

        uint96 exited = module.executeConditionalOrder(exitId);
        assertEq(exited, 100, "activated exit could not execute");
        assertEq(int256(_corePosition(ALICE)), 0, "bracket exit did not flatten");
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

    function testStaleAdvancedLinkCannotTouchFreshGenerationModuleLock() public {
        vm.prank(ALICE);
        uint64 oldParent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            30
        );

        module.executeConditionalOrder(oldParent);

        (,, uint32 oldGeneration) =
            core.pools(IOrderBookCore.Side.Bid, 99);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            99,
            30,
            IOrderBookCore.FillPolicy.IOC
        );

        (,, uint32 rolledGeneration) =
            core.pools(IOrderBookCore.Side.Bid, 99);
        assertTrue(
            rolledGeneration != oldGeneration,
            "old advanced pool generation did not roll"
        );

        // Reopen the same tick through the module before syncing the stale parent.
        vm.prank(ALICE);
        uint64 freshParent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            20
        );
        module.executeConditionalOrder(freshParent);

        (, uint96 freshRemaining, uint32 freshGeneration) =
            core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(freshRemaining, 20, "fresh module quote missing");
        assertEq(
            uint256(freshGeneration),
            uint256(rolledGeneration),
            "fresh module quote used wrong generation"
        );

        module.syncRestingOrder(oldParent);

        assertEq(
            int256(_corePosition(ALICE)),
            30,
            "old generation fill not materialized"
        );
        assertEq(
            module.activeAdvancedOrders(ALICE),
            1,
            "old sync retired fresh advanced parent"
        );

        // This is the lock-integrity check: stale old-generation unlock must not
        // clear or decrement the new-generation module lock.
        vm.prank(ALICE);
        uint96 removed = module.cancelRestingOrder(freshParent);
        assertEq(removed, 20, "fresh generation module lock was corrupted");

        (, uint96 remainingAfter,) =
            core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(remainingAfter, 0, "fresh module liquidity survived cancellation");
        assertEq(
            module.activeAdvancedOrders(ALICE),
            0,
            "fresh parent remained active after cancellation"
        );
        assertEq(
            core.activeQuoteCount(ALICE),
            0,
            "fresh module quote remained active after cancellation"
        );

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(ALICE);
        assertEq(int256(settled), 30, "settled position changed on fresh cancel");
        assertEq(int256(minPosition), 30, "fresh cancel left min reservation");
        assertEq(int256(maxPosition), 30, "fresh cancel left max reservation");
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

        liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        _fund(trader, 5_000);

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
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(closed, 100, "module liquidation close");
        assertEq(int256(_corePosition(trader)), 0, "module liquidation position");
    }

    function testLiquidationSurfacesTerminalBadDebtAfterFullClose() public {
        address trader = address(0xBAD);
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

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 100);
        oracle.record(10);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        uint96 closed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(closed, 100, "bad-debt liquidation did not fully close");
        assertEq(int256(_corePosition(trader)), 0, "bad-debt account left position");
        assertEq(
            liquidation.terminalBadDebt(trader),
            6_000,
            "terminal bad debt not surfaced"
        );
    }

    function testInsuranceCoversTerminalBadDebtAfterFullClose() public {
        address trader = address(0xBEEF);
        _fund(trader, 3_000);

        token.mint(address(this), 6_000);
        core.fundInsurance(6_000);
        assertEq(core.insuranceReserves(), 6_000, "insurance funding mismatch");

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(trader);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 100);
        oracle.record(10);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        uint96 closed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(closed, 100, "insured liquidation did not fully close");
        assertEq(int256(_corePosition(trader)), 0, "insured account left position");
        assertEq(liquidation.terminalBadDebt(trader), 0, "insurance left terminal debt");
        assertEq(core.insuranceReserves(), 0, "insurance reserve not consumed");
        assertEq(core.accountEquity(trader), 0, "insurance over/under covered debt");
    }

    function testLiquidatorRewardComesOnlyFromProtocolFees() public {
        MockERC20 feeToken = new MockERC20();
        SegmentTreeExtremaOracle feeOracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        OrderBookCore feeCore =
            new OrderBookCore(address(feeToken), address(feeOracle), 40, 1_000, 100, 0);
        AdvancedOrderModule feeModule =
            new AdvancedOrderModule(address(feeCore), address(feeOracle));
        LiquidationModule feeLiquidation =
            new LiquidationModule(address(feeCore), address(feeModule), 500);

        feeCore.configureAdvancedModule(address(feeModule));
        feeModule.configureLiquidationModule(address(feeLiquidation));
        feeLiquidation.configureLiquidatorReward(100);

        address trader = address(0xD00D);
        address askMaker = address(0xA551);
        address bidMaker = address(0xB1D1);
        address liquidator = address(0x1A2B);

        _fundOn(feeCore, feeToken, trader, 3_000);
        _fundOn(feeCore, feeToken, askMaker, 100_000);
        _fundOn(feeCore, feeToken, bidMaker, 100_000);

        vm.prank(askMaker);
        feeCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(trader);
        feeCore.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(bidMaker);
        feeCore.addLiquidity(IOrderBookCore.Side.Bid, 70, 100);
        feeOracle.record(70);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        vm.prank(liquidator);
        uint96 closed =
            feeLiquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(closed, 100, "rewarded liquidation did not fully close");
        assertEq(feeToken.balanceOf(liquidator), 70, "liquidator reward mismatch");
        assertEq(feeCore.protocolFeesAccrued(), 100, "reward source accounting mismatch");
        assertEq(
            feeLiquidation.terminalBadDebt(trader),
            170,
            "reward incorrectly changed trader bad debt"
        );
        assertEq(feeCore.insuranceReserves(), 0, "reward consumed insurance");
    }

    function testLiquidatorRewardConfigurationIsOneTime() public {
        liquidation.configureLiquidatorReward(100);
        assertEq(liquidation.liquidatorRewardBps(), 100, "reward config mismatch");

        (bool ok,) = address(liquidation).call(
            abi.encodeCall(liquidation.configureLiquidatorReward, (uint16(200)))
        );
        assertTrue(!ok, "liquidator reward was reconfigured");
    }

    function testMaintenanceMarginUsesNormalizedCollateralUnits() public {
        MockERC20 unitToken = new MockERC20();
        SegmentTreeExtremaOracle unitOracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        OrderBookCore unitCore =
            new OrderBookCore(address(unitToken), address(unitOracle), 40, 1_000, 0, 0);
        AdvancedOrderModule unitModule =
            new AdvancedOrderModule(address(unitCore), address(unitOracle));
        LiquidationModule unitLiquidation =
            new LiquidationModule(address(unitCore), address(unitModule), 500);

        unitCore.configureAccountingUnitScale(1_000);
        unitCore.configureAdvancedModule(address(unitModule));
        unitModule.configureLiquidationModule(address(unitLiquidation));

        _fundOn(unitCore, unitToken, ALICE, 2_000_000);
        _fundOn(unitCore, unitToken, BOB, 2_000_000);

        vm.prank(BOB);
        unitCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);

        vm.prank(ALICE);
        unitCore.take(
            IOrderBookCore.Side.Bid,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(
            unitLiquidation.maintenanceRequirement(ALICE),
            50_000,
            "maintenance margin ignored accounting scale"
        );
    }

    function testPartialLiquidationDoesNotConsumeInsuranceUntilFlat() public {
        address trader = address(0xD15EA5E);
        _fund(trader, 3_000);

        token.mint(address(this), 10_000);
        core.fundInsurance(10_000);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(trader);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 40);
        oracle.record(10);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        uint96 firstClosed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(firstClosed, 40, "partial liquidation fill mismatch");
        assertEq(int256(_corePosition(trader)), 60, "partial liquidation position mismatch");
        assertEq(core.insuranceReserves(), 10_000, "insurance consumed before account was flat");
        assertEq(liquidation.terminalBadDebt(trader), 0, "open position labeled terminal debt");

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 60);

        uint96 secondClosed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(secondClosed, 60, "second liquidation fill mismatch");
        assertEq(int256(_corePosition(trader)), 0, "second liquidation did not flatten account");
        assertEq(liquidation.terminalBadDebt(trader), 0, "insurance failed to cover terminal debt");
        assertTrue(core.insuranceReserves() < 10_000, "insurance not consumed after terminal loss");
    }

    function testProfitableWithdrawalCannotConsumeInsuranceReserveAccounting() public {
        address trader = address(0xFACE);
        _fund(trader, 100_000);

        token.mint(address(this), 25_000);
        core.fundInsurance(25_000);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);

        vm.prank(trader);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 110, 10);

        vm.prank(trader);
        core.take(
            IOrderBookCore.Side.Ask,
            110,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(trader);
        core.withdrawCollateral(100_100);

        assertEq(core.insuranceReserves(), 25_000, "withdrawal debited insurance accounting");
        assertEq(core.accountEquity(trader), 0, "trader retained claim after withdrawal");
        assertTrue(
            token.balanceOf(address(core)) >= core.insuranceReserves(),
            "withdrawal left insurance unbacked"
        );
    }

    function testCancelledOTOChildCanBeReplacedOnSameParent() public {
        vm.prank(ALICE);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            103,
            100
        );

        vm.prank(ALICE);
        uint64 firstExit = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            105,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        uint64 secondExit = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            false,
            90,
            80,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        module.linkOTO(parent, firstExit);
        vm.prank(ALICE);
        module.linkOTO(parent, secondExit);

        vm.prank(ALICE);
        module.cancelConditionalOrder(firstExit);

        vm.prank(ALICE);
        uint64 replacement = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            115,
            110,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        module.linkOTO(parent, replacement);

        module.executeConditionalOrder(parent);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            103,
            40,
            IOrderBookCore.FillPolicy.IOC
        );

        module.syncRestingOrder(parent);

        (, uint96 replacementLots,,,,,,,) = module.conditionalOrders(replacement);
        (, uint96 secondLots,,,,,,,) = module.conditionalOrders(secondExit);

        assertEq(replacementLots, 40, "replacement OTO exit not resized");
        assertEq(secondLots, 40, "existing OTO exit not resized");
    }

    function testLiquidationCleanupMixedOTOGraphReturnsAdvancedCountToZero() public {
        address trader = address(0xC1EA4);
        _fund(trader, 3_000);

        vm.prank(trader);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            103,
            100
        );

        vm.prank(trader);
        uint64 tp = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            105,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(trader);
        uint64 sl = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            false,
            90,
            80,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(trader);
        module.linkOCO(tp, sl);
        vm.prank(trader);
        module.linkOTO(parent, tp);
        vm.prank(trader);
        module.linkOTO(parent, sl);

        module.executeConditionalOrder(parent);

        uint64[] memory conditionals = new uint64[](3);
        conditionals[0] = parent;
        conditionals[1] = tp;
        conditionals[2] = sl;
        uint64[] memory trailings = new uint64[](0);

        vm.prank(address(liquidation));
        module.liquidationCleanupAdvanced(trader, conditionals, trailings);

        assertEq(module.activeAdvancedOrders(trader), 0, "liquidation cleanup stranded advanced order");
        assertEq(core.activeQuoteCount(trader), 0, "liquidation cleanup stranded core quote");
    }

    function testOTOExitFOKFailureRestoresRestingParentAndGraph() public {
        vm.prank(ALICE);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            100
        );

        vm.prank(ALICE);
        uint64 exit = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            100,
            100,
            100,
            IOrderBookCore.FillPolicy.FOK,
            true
        );

        vm.prank(ALICE);
        uint64 sibling = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        module.linkOCO(exit, sibling);
        vm.prank(ALICE);
        module.linkOTO(parent, exit);
        vm.prank(ALICE);
        module.linkOTO(parent, sibling);

        module.executeConditionalOrder(parent);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            99,
            40,
            IOrderBookCore.FillPolicy.IOC
        );

        module.syncRestingOrder(parent);

        bytes32 stateBefore =
            _otoFOKRollbackState(parent, exit, sibling);

        assertTrue(
            !_attemptConditionalExecution(exit),
            "OTO FOK exit unexpectedly succeeded without bids"
        );

        assertEq(
            uint256(_otoFOKRollbackState(parent, exit, sibling)),
            uint256(stateBefore),
            "failed exit changed OTO/core rollback state"
        );

        // The restored parent must still be cancellable, proving its lock/link
        // survived the failed child transaction.
        vm.prank(ALICE);
        uint96 removed = module.cancelRestingOrder(parent);
        assertEq(removed, 60, "restored parent could not cancel its live remainder");
        assertEq(core.activeQuoteCount(ALICE), 0, "parent quote remained after cancellation");

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 40);

        uint96 filled = module.executeConditionalOrder(exit);
        assertEq(filled, 40, "restored OTO FOK exit did not execute");
        assertEq(int256(_corePosition(ALICE)), 0, "restored OTO exit did not flatten position");
        assertEq(module.activeAdvancedOrders(ALICE), 0, "OCO sibling survived successful exit");
    }

    function _attemptConditionalExecution(uint64 orderId)
        internal
        returns (bool ok)
    {
        (ok,) = address(module).call(
            abi.encodeCall(module.executeConditionalOrder, (orderId))
        );
    }

    function _otoFOKRollbackState(
        uint64 parent,
        uint64 exit,
        uint64 sibling
    ) internal view returns (bytes32) {
        (, uint96 exitLots, uint64 exitSibling,,,,,, uint8 exitFlags) =
            module.conditionalOrders(exit);
        (, uint96 siblingLots, uint64 siblingBack,,,,,, uint8 siblingFlags) =
            module.conditionalOrders(sibling);
        (uint128 parentShares, uint96 parentClaim, uint32 parentGeneration) =
            core.quotes(ALICE, IOrderBookCore.Side.Bid, 99);
        (, uint256 reserved) = core.marginStateTest(ALICE);

        return keccak256(
            abi.encode(
                exitLots,
                exitSibling,
                exitFlags,
                siblingLots,
                siblingBack,
                siblingFlags,
                parentShares,
                parentClaim,
                parentGeneration,
                reserved,
                module.activeAdvancedOrders(ALICE),
                core.activeQuoteCount(ALICE)
            )
        );
    }

    function testOCOExecutionAndSiblingCancellationConserveReservation() public {
        vm.prank(ALICE);
        uint64 first = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            100,
            40,
            IOrderBookCore.FillPolicy.IOC,
            false
        );

        vm.prank(ALICE);
        uint64 second = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            false,
            90,
            90,
            30,
            IOrderBookCore.FillPolicy.IOC,
            false
        );

        vm.prank(ALICE);
        module.linkOCO(first, second);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 25);

        uint96 filled = module.executeConditionalOrder(first);
        assertEq(filled, 25, "OCO execution fill mismatch");

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(ALICE);

        assertEq(int256(settled), 25, "filled OCO leg not materialized");
        assertEq(int256(minPosition), 25, "OCO min reservation not conserved");
        assertEq(int256(maxPosition), 25, "OCO sibling/unfilled reservation leaked");
        assertEq(module.activeAdvancedOrders(ALICE), 0, "OCO lifecycle remained active");
    }

    function testDelayedAdvancedParentSettlementPreservesFundingAttribution() public {
        vm.prank(ALICE);
        uint64 parent = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            100
        );

        vm.prank(ALICE);
        uint64 exitId = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        module.linkOTO(parent, exitId);
        module.executeConditionalOrder(parent);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            99,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        core.setFundingIndex(int128(2e18));

        module.syncRestingOrder(parent);

        assertEq(int256(_corePosition(ALICE)), 100, "advanced maker fill not materialized");
        assertEq(
            core.accountEquity(ALICE),
            999_900,
            "delayed maker funding attribution mismatch"
        );

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 100);
        oracle.record(110);

        uint96 exited = module.executeConditionalOrder(exitId);
        assertEq(exited, 100, "funded advanced exit failed");
        assertEq(int256(_corePosition(ALICE)), 0, "funded advanced exit did not flatten");
        assertEq(
            core.accountEquity(ALICE),
            999_900,
            "funding cashflow changed when closing after sync"
        );
    }

    function testAdvancedRestingSyncUsesCoreCeilClaimRounding() public {
        MockERC20 roundToken = new MockERC20();
        SegmentTreeExtremaOracle roundOracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        OrderBookCore roundCore =
            new OrderBookCore(address(roundToken), address(roundOracle), 40, 1_000, 0, 0);
        AdvancedOrderModuleHarness roundModule =
            new AdvancedOrderModuleHarness(address(roundCore), address(roundOracle));

        roundCore.configureAdvancedModule(address(roundModule));

        _fundOn(roundCore, roundToken, ALICE, 100_000);
        _fundOn(roundCore, roundToken, BOB, 100_000);
        _fundOn(roundCore, roundToken, CAROL, 100_000);

        vm.prank(ALICE);
        uint64 parent = roundModule.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            1
        );

        vm.prank(ALICE);
        uint64 exitId = roundModule.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            105,
            1,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        roundModule.linkOTO(parent, exitId);
        roundModule.executeConditionalOrder(parent);

        // Join the same tick after Alice. With 3 lots total, consuming one lot
        // leaves Alice's pro-rata claim at ceil(2/3) = 1, not floor(2/3) = 0.
        vm.prank(BOB);
        roundCore.addLiquidity(IOrderBookCore.Side.Bid, 99, 2);

        vm.prank(CAROL);
        roundCore.take(
            IOrderBookCore.Side.Ask,
            99,
            1,
            IOrderBookCore.FillPolicy.IOC
        );

        roundModule.syncRestingOrder(parent);

        (, uint96 remainingClaim, uint96 cumulativeFilled,, bool active) =
            roundModule.restingLinkTest(parent);

        assertTrue(active, "parent link retired under rounding-only fill");
        assertEq(remainingClaim, 1, "advanced claim did not use core ceil rounding");
        assertEq(cumulativeFilled, 0, "advanced module invented maker fill from rounding");

        (, uint96 exitLots,,,,,,, uint8 flags) =
            roundModule.conditionalOrders(exitId);
        assertEq(exitLots, 1, "dormant exit size changed under rounding-only fill");
        assertTrue((flags & uint8(1 << 4)) != 0, "dormant exit activated without maker fill");

        (int80 settled,,) = roundCore.accountRisk(ALICE);
        assertEq(int256(settled), 0, "maker position materialized from rounding only");
    }

    function testExecutedOTOChildUnlinksFromParentGraph() public {
        MockERC20 graphToken = new MockERC20();
        SegmentTreeExtremaOracle graphOracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        OrderBookCore graphCore =
            new OrderBookCore(address(graphToken), address(graphOracle), 40, 1_000, 0, 0);
        AdvancedOrderModuleHarness graphModule =
            new AdvancedOrderModuleHarness(address(graphCore), address(graphOracle));

        graphCore.configureAdvancedModule(address(graphModule));

        _fundOn(graphCore, graphToken, ALICE, 100_000);
        _fundOn(graphCore, graphToken, BOB, 100_000);
        _fundOn(graphCore, graphToken, CAROL, 100_000);

        vm.prank(ALICE);
        uint64 parent = graphModule.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            103,
            40
        );

        vm.prank(ALICE);
        uint64 exitId = graphModule.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            true,
            110,
            105,
            40,
            IOrderBookCore.FillPolicy.IOC,
            true
        );

        vm.prank(ALICE);
        graphModule.linkOTO(parent, exitId);

        graphModule.executeConditionalOrder(parent);

        vm.prank(BOB);
        graphCore.take(
            IOrderBookCore.Side.Ask,
            103,
            40,
            IOrderBookCore.FillPolicy.IOC
        );

        graphModule.syncRestingOrder(parent);

        vm.prank(CAROL);
        graphCore.addLiquidity(IOrderBookCore.Side.Bid, 110, 40);
        graphOracle.record(110);

        uint96 exited = graphModule.executeConditionalOrder(exitId);
        assertEq(exited, 40, "OTO exit failed");

        (uint64 childOne, uint64 childTwo, uint64 parentOfChild, uint96 childMaxLots) =
            graphModule.otoGraphTest(parent, exitId);

        assertEq(uint256(childOne), 0, "executed child left parent slot one");
        assertEq(uint256(childTwo), 0, "executed child left parent slot two");
        assertEq(uint256(parentOfChild), 0, "executed child kept parent backlink");
        assertEq(uint256(childMaxLots), 0, "executed child kept max-lot metadata");
    }

    function testWithdrawalRespectsAdvancedReservationWithoutCoreQuote() public {
        vm.prank(ALICE);
        uint64 orderId = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            120,
            120,
            100,
            IOrderBookCore.FillPolicy.IOC,
            false
        );

        assertEq(core.activeQuoteCount(ALICE), 0, "conditional unexpectedly created core quote");

        vm.prank(ALICE);
        (bool tooMuchOk,) = address(core).call(
            abi.encodeCall(core.withdrawCollateral, (uint256(998_601)))
        );
        assertTrue(!tooMuchOk, "withdrawal bypassed advanced reserved margin");

        vm.prank(ALICE);
        core.withdrawCollateral(998_600);

        vm.prank(ALICE);
        module.cancelConditionalOrder(orderId);

        vm.prank(ALICE);
        core.withdrawCollateral(1_400);

        assertEq(core.accountEquity(ALICE), 0, "advanced reservation not fully released");
        assertEq(module.activeAdvancedOrders(ALICE), 0, "cancelled conditional remained active");
    }

    function testHealthyLiquidationAttemptRollsBackMakerQuoteCleanup() public {
        address trader = address(0xA11C);
        _fund(trader, 100_000);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);

        vm.prank(trader);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(trader);
        core.addLiquidity(IOrderBookCore.Side.Ask, 110, 20);

        bytes32 stateBefore = _healthyMakerCleanupState(trader);

        assertTrue(
            !_attemptLiquidationMakerQuote(trader),
            "healthy quoted account was liquidated"
        );

        assertEq(
            uint256(_healthyMakerCleanupState(trader)),
            uint256(stateBefore),
            "failed liquidation changed maker cleanup state"
        );
    }

    function _attemptLiquidationMakerQuote(address trader)
        internal
        returns (bool ok)
    {
        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](1);
        sides[0] = IOrderBookCore.Side.Ask;
        uint16[] memory ticks = new uint16[](1);
        ticks[0] = 110;
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        (ok,) = address(liquidation).call(
            abi.encodeCall(
                liquidation.liquidate,
                (trader, sides, ticks, conditionals, trailings)
            )
        );
    }

    function _healthyMakerCleanupState(address trader)
        internal
        view
        returns (bytes32)
    {
        (uint128 shares, uint96 claim, uint32 generation) =
            core.quotes(trader, IOrderBookCore.Side.Ask, 110);
        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(trader);

        return keccak256(
            abi.encode(
                shares,
                claim,
                generation,
                core.activeQuoteCount(trader),
                settled,
                minPosition,
                maxPosition
            )
        );
    }

    function testHealthyLiquidationAttemptRollsBackAdvancedCleanup() public {
        address trader = address(0xA11D);
        _fund(trader, 100_000);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);

        vm.prank(trader);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(trader);
        uint64 conditionalId = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            120,
            120,
            20,
            IOrderBookCore.FillPolicy.IOC,
            false
        );

        assertEq(module.activeAdvancedOrders(trader), 1, "conditional not active before liquidation");

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](1);
        conditionals[0] = conditionalId;
        uint64[] memory trailings = new uint64[](0);

        (bool ok,) = address(liquidation).call(
            abi.encodeCall(
                liquidation.liquidate,
                (trader, sides, ticks, conditionals, trailings)
            )
        );
        assertTrue(!ok, "healthy account was liquidated");

        assertEq(
            module.activeAdvancedOrders(trader),
            1,
            "failed liquidation did not roll back advanced cleanup"
        );

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(trader);
        assertEq(int256(settled), 10, "failed liquidation changed position");
        assertEq(int256(minPosition), 10, "failed liquidation changed min envelope");
        assertEq(int256(maxPosition), 30, "failed liquidation released reservation");
    }

    function testLiquidationForceCancelInvalidatesManagedQuoteMetadata() public {
        address trader = address(0xFD01);
        _fund(trader, 5_000);

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
            side: IOrderBookCore.Side.Bid,
            tick: 95,
            lots: 1
        });

        vm.prank(trader);
        marketMaker.batchReplaceQuotes(updates);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 2);

        (, uint96 beforeLiquidation, uint32 generationBefore) =
            core.pools(IOrderBookCore.Side.Bid, 95);
        assertEq(beforeLiquidation, 3, "managed test pool setup mismatch");

        oracle.record(50);
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 100);

        assertEq(
            _liquidateManagedMetadataTrader(trader),
            100,
            "liquidation did not flatten trader"
        );

        (, uint96 afterLiquidation, uint32 generationAfter) =
            core.pools(IOrderBookCore.Side.Bid, 95);
        assertEq(afterLiquidation, 2, "force cancel did not remove managed lot");
        assertEq(
            uint256(generationAfter),
            uint256(generationBefore),
            "neighbor liquidity should keep pool generation live"
        );

        _fund(trader, 5_000);
        oracle.record(100);

        // If liquidation leaves stale managed metadata, this refresh sees the
        // deleted old shares as a live 1-lot slice and adds nothing.
        vm.prank(trader);
        marketMaker.batchReplaceQuotes(updates);

        _assertManagedMetadataRefresh(trader);
    }

    function _liquidateManagedMetadataTrader(address trader)
        internal
        returns (uint96 closed)
    {
        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](1);
        sides[0] = IOrderBookCore.Side.Bid;
        uint16[] memory ticks = new uint16[](1);
        ticks[0] = 95;
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        closed = liquidation.liquidate(
            trader,
            sides,
            ticks,
            conditionals,
            trailings,
            new uint64[](0)
        );
    }

    function _assertManagedMetadataRefresh(address trader) internal view {
        (, uint96 afterRefresh, uint32 generationFinal) =
            core.pools(IOrderBookCore.Side.Bid, 95);
        (uint128 traderShares, uint96 traderClaim, uint32 traderGeneration) =
            core.quotes(trader, IOrderBookCore.Side.Bid, 95);

        assertEq(afterRefresh, 3, "managed refresh preserved phantom shares");
        assertTrue(traderShares != 0, "managed refresh did not mint fresh shares");
        assertEq(traderClaim, 1, "managed refresh claim mismatch");
        assertEq(
            uint256(traderGeneration),
            uint256(generationFinal),
            "fresh managed quote generation mismatch"
        );
    }

    function testLiquidationForceCancelCrystallizesRoundingBoundaryMakerFill() public {
        address trader = address(0xFC01);
        address counterparty = address(0xFC02);
        _fund(trader, 3_000);
        _fund(counterparty, 100_000);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(trader);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(trader);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 1);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 2);

        vm.prank(counterparty);
        core.take(
            IOrderBookCore.Side.Ask,
            95,
            1,
            IOrderBookCore.FillPolicy.IOC
        );

        // Trader owns one third of the bid shares. One of three lots has traded,
        // leaving a ceil claim of 1 but floor redemption of 0 for the trader slice.
        oracle.record(50);
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 101);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](1);
        sides[0] = IOrderBookCore.Side.Bid;
        uint16[] memory ticks = new uint16[](1);
        ticks[0] = 95;
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        uint96 closed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(
            closed,
            101,
            "forced cancel discarded burn-attributed maker fill"
        );
        assertEq(
            core.activeQuoteCount(trader),
            0,
            "forced cancel left maker quote active"
        );

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(trader);
        assertEq(int256(settled), 0, "liquidation did not flatten crystallized position");
        assertEq(int256(minPosition), 0, "forced cancel left min reservation");
        assertEq(int256(maxPosition), 0, "forced cancel left max reservation");

        (, uint96 neighborRemaining,) =
            core.pools(IOrderBookCore.Side.Bid, 95);
        assertEq(
            neighborRemaining,
            2,
            "forced cancel removed neighboring maker liquidity"
        );
    }

    function testLiquidationCleansReservedExposureBeforeClosingPosition() public {
        address trader = address(0xA11E);
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

        vm.prank(trader);
        uint64 conditionalId = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            120,
            120,
            50,
            IOrderBookCore.FillPolicy.IOC,
            false
        );

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 100);
        oracle.record(10);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](1);
        conditionals[0] = conditionalId;
        uint64[] memory trailings = new uint64[](0);

        uint96 closed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(closed, 100, "liquidation close size included reserved exposure");
        assertEq(module.activeAdvancedOrders(trader), 0, "advanced reservation survived liquidation");
        assertEq(int256(_corePosition(trader)), 0, "liquidation did not flatten settled position");

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(trader);
        assertEq(int256(settled), 0, "settled position not flat");
        assertEq(int256(minPosition), 0, "min envelope retained cancelled reservation");
        assertEq(int256(maxPosition), 0, "max envelope retained cancelled reservation");
    }

    function testLiquidationExecutesAtLowerBandBoundary() public {
        address trader = address(0xBAA1);
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

        oracle.record(50);

        // executionBandTicks = 40, so the lower executable boundary is 10.
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 100);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        uint96 closed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(closed, 100, "lower band boundary was not executable");
        assertEq(int256(_corePosition(trader)), 0, "boundary liquidation did not flatten");
    }

    function testLiquidationSkipsLiquidityBelowExecutionBand() public {
        address trader = address(0xBAA2);
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

        oracle.record(50);

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 9, 100);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        uint96 closed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(closed, 0, "liquidation crossed below execution band");
        assertEq(int256(_corePosition(trader)), 100, "out-of-band liquidity changed position");

        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Bid, 9);
        assertEq(remaining, 100, "out-of-band liquidity was consumed");
    }

    function testLiquidationUsesOnlyInBandDepthAndLeavesResidualPosition() public {
        address trader = address(0xBAA3);
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

        oracle.record(50);

        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 40);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Bid, 9, 60);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        uint96 closed =
            liquidation.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));

        assertEq(closed, 40, "liquidation did not stop at band boundary");
        assertEq(int256(_corePosition(trader)), 60, "partial liquidation residual mismatch");

        (, uint96 belowBandRemaining,) =
            core.pools(IOrderBookCore.Side.Bid, 9);
        assertEq(belowBandRemaining, 60, "below-band depth was consumed");
        assertEq(
            liquidation.terminalBadDebt(trader),
            0,
            "residual position incorrectly surfaced terminal debt"
        );
    }

    function testZeroCloseLiquidationPaysNoRewardAndConsumesNoInsurance() public {
        MockERC20 feeToken = new MockERC20();
        SegmentTreeExtremaOracle feeOracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        OrderBookCore feeCore =
            new OrderBookCore(address(feeToken), address(feeOracle), 40, 1_000, 100, 0);
        AdvancedOrderModule feeModule =
            new AdvancedOrderModule(address(feeCore), address(feeOracle));
        LiquidationModule feeLiquidation =
            new LiquidationModule(address(feeCore), address(feeModule), 500);

        feeCore.configureAdvancedModule(address(feeModule));
        feeModule.configureLiquidationModule(address(feeLiquidation));
        feeLiquidation.configureLiquidatorReward(100);

        address trader = address(0xF001);
        address askMaker = address(0xF002);
        address liquidator = address(0xF003);

        _fundOn(feeCore, feeToken, trader, 3_000);
        _fundOn(feeCore, feeToken, askMaker, 100_000);

        feeToken.mint(address(this), 10_000);
        feeToken.approve(address(feeCore), type(uint256).max);
        feeCore.fundInsurance(10_000);

        vm.prank(askMaker);
        feeCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(trader);
        feeCore.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        // Taker fee accrues protocol funds, but no executable close liquidity exists.
        feeOracle.record(50);

        bytes32 stateBefore =
            _zeroCloseState(feeCore, feeToken, trader, liquidator);

        uint96 closed =
            _liquidateWithoutCleanup(feeLiquidation, trader, liquidator);

        assertEq(closed, 0, "zero-depth liquidation unexpectedly closed");
        assertEq(
            uint256(_zeroCloseState(feeCore, feeToken, trader, liquidator)),
            uint256(stateBefore),
            "zero close mutated protected state"
        );
    }

    function _liquidateWithoutCleanup(
        LiquidationModule target,
        address trader,
        address liquidator
    ) internal returns (uint96 closed) {
        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);
        uint64[] memory trailings = new uint64[](0);

        vm.prank(liquidator);
        closed =
            target.liquidate(trader, sides, ticks, conditionals, trailings, new uint64[](0));
    }

    function _zeroCloseState(
        OrderBookCore target,
        MockERC20 targetToken,
        address trader,
        address liquidator
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                target.protocolFeesAccrued(),
                target.insuranceReserves(),
                targetToken.balanceOf(liquidator),
                _positionOn(target, trader)
            )
        );
    }

    function testPartialLiquidationRewardAndRetryAreProportionalToClosedLots() public {
        MockERC20 feeToken = new MockERC20();
        SegmentTreeExtremaOracle feeOracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        OrderBookCore feeCore =
            new OrderBookCore(address(feeToken), address(feeOracle), 40, 1_000, 100, 0);
        AdvancedOrderModule feeModule =
            new AdvancedOrderModule(address(feeCore), address(feeOracle));
        LiquidationModule feeLiquidation =
            new LiquidationModule(address(feeCore), address(feeModule), 500);

        feeCore.configureAdvancedModule(address(feeModule));
        feeModule.configureLiquidationModule(address(feeLiquidation));
        feeLiquidation.configureLiquidatorReward(100);

        address trader = address(0xF011);
        address askMaker = address(0xF012);
        address bidMaker = address(0xF013);
        address liquidator = address(0xF014);

        _fundOn(feeCore, feeToken, trader, 3_000);
        _fundOn(feeCore, feeToken, askMaker, 100_000);
        _fundOn(feeCore, feeToken, bidMaker, 100_000);

        feeToken.mint(address(this), 20_000);
        feeToken.approve(address(feeCore), type(uint256).max);
        feeCore.fundInsurance(20_000);

        vm.prank(askMaker);
        feeCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(trader);
        feeCore.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        feeOracle.record(50);

        vm.prank(bidMaker);
        feeCore.addLiquidity(IOrderBookCore.Side.Bid, 50, 40);

        uint256 insuranceBefore = feeCore.insuranceReserves();

        uint96 firstClosed =
            _liquidateWithoutCleanup(feeLiquidation, trader, liquidator);

        assertEq(firstClosed, 40, "first partial close mismatch");
        assertEq(int256(_positionOn(feeCore, trader)), 60, "first residual position mismatch");
        assertEq(feeCore.insuranceReserves(), insuranceBefore, "partial close consumed insurance");
        assertEq(feeToken.balanceOf(liquidator), 20, "first reward not proportional to closed lots");

        vm.prank(bidMaker);
        feeCore.addLiquidity(IOrderBookCore.Side.Bid, 50, 60);

        uint96 secondClosed =
            _liquidateWithoutCleanup(feeLiquidation, trader, liquidator);

        assertEq(secondClosed, 60, "second close mismatch");
        assertEq(int256(_positionOn(feeCore, trader)), 0, "retry did not flatten position");
        assertEq(feeToken.balanceOf(liquidator), 50, "cumulative reward mismatch");
        assertTrue(feeCore.insuranceReserves() < insuranceBefore, "terminal loss did not use insurance");
        assertEq(feeLiquidation.terminalBadDebt(trader), 0, "retry left terminal debt");
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
    function testTriggeredPostOnlyPlacementEmitsDistinctSemanticEvent() public {
        vm.recordLogs();
        vm.prank(ALICE);
        uint64 orderId = module.placeTriggeredPostOnlyOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            25
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature = keccak256("TriggeredPostOnlyOrderPlaced(uint64)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(module) && logs[i].topics.length == 2
                    && logs[i].topics[0] == signature
                    && uint64(uint256(logs[i].topics[1])) == orderId
            ) {
                found = true;
                break;
            }
        }
        assertTrue(found, "post-only placement event missing");
    }

    function testTriggeredPostOnlyRestsWithoutTaking() public {
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 40);

        vm.prank(ALICE);
        uint64 orderId = module.placeTriggeredPostOnlyOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            25
        );

        uint96 filled = module.executeConditionalOrder(orderId);
        assertEq(filled, 0, "post-only order took liquidity");

        (, uint96 askLots,) = core.pools(IOrderBookCore.Side.Ask, 100);
        (, uint96 bidLots,) = core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(askLots, 40, "opposite liquidity changed");
        assertEq(bidLots, 25, "post-only liquidity did not rest");
    }

    function testTriggeredPostOnlyRevertsAtomicallyWhenItWouldCross() public {
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 40);

        vm.prank(ALICE);
        uint64 orderId = module.placeTriggeredPostOnlyOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            100,
            25
        );

        (bool ok,) = address(module).call(
            abi.encodeCall(module.executeConditionalOrder, (orderId))
        );
        assertTrue(!ok, "crossing post-only order executed");

        (, uint96 askLots,) = core.pools(IOrderBookCore.Side.Ask, 100);
        (, uint96 bidLots,) = core.pools(IOrderBookCore.Side.Bid, 100);
        assertEq(askLots, 40, "crossing attempt took liquidity");
        assertEq(bidLots, 0, "crossing attempt rested liquidity");

        vm.prank(ALICE);
        module.cancelConditionalOrder(orderId);
        assertEq(module.activeAdvancedOrders(ALICE), 0, "failed post-only could not cancel");
    }

    function testConditionalGTDClearsOnNormalCancel() public {
        vm.prank(ALICE);
        uint64 orderId = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            100,
            25,
            IOrderBookCore.FillPolicy.IOC,
            false
        );
        vm.prank(ALICE);
        module.setConditionalExpiry(orderId, uint64(block.timestamp + 60));

        vm.prank(ALICE);
        module.cancelConditionalOrder(orderId);

        assertEq(uint256(module.conditionalExpiry(orderId)), 0, "cancel left conditional expiry");
    }

    function testConditionalGTDClearsOnExecutionAndOCOSiblingCancel() public {
        vm.prank(ALICE);
        uint64 first = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC,
            false
        );
        vm.prank(ALICE);
        uint64 second = module.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            false,
            100,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC,
            false
        );

        vm.prank(ALICE);
        module.setConditionalExpiry(first, uint64(block.timestamp + 60));
        vm.prank(ALICE);
        module.setConditionalExpiry(second, uint64(block.timestamp + 60));
        vm.prank(ALICE);
        module.linkOCO(first, second);

        module.executeConditionalOrder(first);

        assertEq(uint256(module.conditionalExpiry(first)), 0, "execution left conditional expiry");
        assertEq(uint256(module.conditionalExpiry(second)), 0, "OCO cancel left sibling expiry");
    }

    function testTriggeredLimitGTDRetainsExpiryWhileRestingAndClearsOnCancel() public {
        vm.prank(ALICE);
        uint64 orderId = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            30
        );
        uint64 expiry = uint64(block.timestamp + 60);
        vm.prank(ALICE);
        module.setConditionalExpiry(orderId, expiry);

        module.executeConditionalOrder(orderId);
        assertEq(
            uint256(module.conditionalExpiry(orderId)),
            uint256(expiry),
            "resting triggered limit lost expiry"
        );

        vm.prank(ALICE);
        module.cancelConditionalOrder(orderId);
        assertEq(uint256(module.conditionalExpiry(orderId)), 0, "resting cancel left expiry");
    }

    function testTrailingGTDClearsOnNormalCancelAndExecution() public {
        vm.prank(ALICE);
        uint64 cancelled = module.placeTrailingOrder(
            IOrderBookCore.Side.Ask,
            10,
            90,
            20,
            IOrderBookCore.FillPolicy.IOC,
            false
        );
        vm.prank(ALICE);
        module.setTrailingExpiry(cancelled, uint64(block.timestamp + 60));
        vm.prank(ALICE);
        module.cancelTrailingOrder(cancelled);
        assertEq(uint256(module.trailingExpiry(cancelled)), 0, "cancel left trailing expiry");

        vm.prank(ALICE);
        uint64 executed = module.placeTrailingOrder(
            IOrderBookCore.Side.Ask,
            10,
            90,
            20,
            IOrderBookCore.FillPolicy.IOC,
            false
        );
        vm.prank(ALICE);
        module.setTrailingExpiry(executed, uint64(block.timestamp + 60));

        oracle.record(120);
        oracle.record(100);
        module.executeTrailingOrder(executed);

        assertEq(uint256(module.trailingExpiry(executed)), 0, "execution left trailing expiry");
    }

    function testConditionalGTDRejectsExecutionAndPermissionlesslyExpires() public {
        vm.prank(ALICE);
        uint64 orderId = module.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            100,
            25,
            IOrderBookCore.FillPolicy.IOC,
            false
        );

        vm.prank(ALICE);
        module.setConditionalExpiry(orderId, uint64(block.timestamp + 60));

        vm.warp(block.timestamp + 60);
        (bool ok,) = address(module).call(
            abi.encodeCall(module.executeConditionalOrder, (orderId))
        );
        assertTrue(!ok, "expired conditional executed");

        vm.prank(BOB);
        module.expireConditionalOrder(orderId);
        assertEq(module.activeAdvancedOrders(ALICE), 0, "expired conditional remained active");
        assertEq(uint256(module.conditionalExpiry(orderId)), 0, "conditional expiry not cleared");
    }

    function testTriggeredLimitGTDExpiresRestingRemainder() public {
        vm.prank(ALICE);
        uint64 orderId = module.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            30
        );
        vm.prank(ALICE);
        module.setConditionalExpiry(orderId, uint64(block.timestamp + 60));

        module.executeConditionalOrder(orderId);
        (, uint96 beforeExpiry,) = core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(beforeExpiry, 30, "triggered limit did not rest");

        vm.warp(block.timestamp + 60);
        vm.prank(CAROL);
        module.expireConditionalOrder(orderId);

        (, uint96 afterExpiry,) = core.pools(IOrderBookCore.Side.Bid, 99);
        assertEq(afterExpiry, 0, "expired triggered limit left resting liquidity");
        assertEq(module.activeAdvancedOrders(ALICE), 0, "expired resting order remained active");
    }

    function testTrailingGTDRejectsExecutionAndPermissionlesslyExpires() public {
        vm.prank(ALICE);
        uint64 orderId = module.placeTrailingOrder(
            IOrderBookCore.Side.Ask,
            10,
            90,
            20,
            IOrderBookCore.FillPolicy.IOC,
            false
        );
        vm.prank(ALICE);
        module.setTrailingExpiry(orderId, uint64(block.timestamp + 30));

        vm.warp(block.timestamp + 30);
        (bool ok,) = address(module).call(
            abi.encodeCall(module.executeTrailingOrder, (orderId))
        );
        assertTrue(!ok, "expired trailing order executed");

        vm.prank(BOB);
        module.expireTrailingOrder(orderId);
        assertEq(module.activeAdvancedOrders(ALICE), 0, "expired trailing remained active");
        assertEq(uint256(module.trailingExpiry(orderId)), 0, "trailing expiry not cleared");
    }

    function _packUpdates(MarketMakerModule.QuoteUpdate[] memory updates)
        internal
        pure
        returns (bytes memory packed)
    {
        for (uint256 i; i < updates.length; ++i) {
            MarketMakerModule.QuoteUpdate memory update = updates[i];
            uint128 word =
                uint128(update.lots)
                    | (uint128(update.tick) << 96)
                    | (uint128(uint8(update.side)) << 112);
            packed = bytes.concat(packed, bytes16(word));
        }
    }

    function _positionOn(OrderBookCore target, address account)
        internal
        view
        returns (int80 position)
    {
        (position,,) = target.accountRisk(account);
    }

    function _corePosition(address account) internal view returns (int80 position) {
        (position,,) = core.accountRisk(account);
    }

}

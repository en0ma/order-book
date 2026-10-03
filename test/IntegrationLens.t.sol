// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {IntegrationLens} from "../src/deployable/IntegrationLens.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract IntegrationLensTest is TestBase {
    OrderBookCore internal core;
    AdvancedOrderModule internal advanced;
    MarketMakerModule internal marketMaker;
    IntegrationLens internal lens;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCore(address(token), address(oracle), 40, 1_000, 0, 0);
        advanced = new AdvancedOrderModule(address(core), address(oracle));
        marketMaker = new MarketMakerModule(address(core), address(advanced));
        lens = new IntegrationLens(address(core), address(advanced));

        core.configureAdvancedModule(address(advanced));
        advanced.configureMarketMakerModule(address(marketMaker));

        token.mint(ALICE, 1_000_000);
        token.mint(BOB, 1_000_000);

        vm.prank(ALICE);
        token.approve(address(core), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(core), type(uint256).max);
        vm.prank(ALICE);
        core.depositCollateral(500_000);
        vm.prank(BOB);
        core.depositCollateral(500_000);
    }

    function testLensBatchesPoolsAndBoundedDepth() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 10);
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Bid, 97, 20);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 103, 30);

        IntegrationLens.TickKey[] memory keys = new IntegrationLens.TickKey[](3);
        keys[0] = IntegrationLens.TickKey(IOrderBookCore.Side.Bid, 95);
        keys[1] = IntegrationLens.TickKey(IOrderBookCore.Side.Bid, 97);
        keys[2] = IntegrationLens.TickKey(IOrderBookCore.Side.Ask, 103);

        IntegrationLens.PoolState[] memory pools = lens.poolStates(keys);
        assertEq(uint256(pools[0].remainingLots), 10, "bid95 pool");
        assertEq(uint256(pools[1].remainingLots), 20, "bid97 pool");
        assertEq(uint256(pools[2].remainingLots), 30, "ask103 pool");

        IntegrationLens.PoolState[] memory bids =
            lens.depthInRange(IOrderBookCore.Side.Bid, 94, 98, 4);
        assertEq(bids.length, 2, "bid depth count");
        assertEq(uint256(bids[0].tick), 97, "best bid first");
        assertEq(uint256(bids[1].tick), 95, "second bid");

        IntegrationLens.PoolState[] memory asks =
            lens.depthInRange(IOrderBookCore.Side.Ask, 100, 105, 4);
        assertEq(asks.length, 1, "ask depth count");
        assertEq(uint256(asks[0].tick), 103, "best ask");
    }

    function testLensPreviewsLiveLazyMakerFillExactly() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 100);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Ask,
            95,
            40,
            IOrderBookCore.FillPolicy.IOC
        );

        IntegrationLens.TickKey[] memory keys = new IntegrationLens.TickKey[](1);
        keys[0] = IntegrationLens.TickKey(IOrderBookCore.Side.Bid, 95);

        IntegrationLens.QuoteState[] memory quotes = lens.quoteStates(ALICE, keys);
        assertEq(uint256(quotes[0].claimLots), 100, "claim mutated before settle");
        assertEq(uint256(quotes[0].currentRedeemableLots), 60, "redeemable claim");
        assertEq(uint256(quotes[0].pendingFillLots), 40, "lazy fill preview");
        assertEq(int256(_position(ALICE)), 0, "preview materialized maker");
    }

    function testLensPreviewsFinalMakerAcrossGenerationRollover() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 10);

        (, , uint32 quoteGeneration) =
            core.quotes(ALICE, IOrderBookCore.Side.Ask, 105);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        IntegrationLens.TickKey[] memory keys = new IntegrationLens.TickKey[](1);
        keys[0] = IntegrationLens.TickKey(IOrderBookCore.Side.Ask, 105);
        IntegrationLens.QuoteState[] memory quotes = lens.quoteStates(ALICE, keys);

        assertEq(uint256(quotes[0].generation), uint256(quoteGeneration), "quote generation");
        assertEq(
            uint256(quotes[0].poolGeneration),
            uint256(quoteGeneration + 1),
            "pool did not roll"
        );
        assertEq(uint256(quotes[0].currentRedeemableLots), 0, "stale quote redeemable");
        assertEq(uint256(quotes[0].pendingFillLots), 10, "stale final-maker preview");
    }

    function testLensReadsAdvancedLifecycleAndManagedQuotes() public {
        vm.prank(ALICE);
        uint64 conditionalId = advanced.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            99,
            25
        );
        uint64 expiry = uint64(block.timestamp + 600);
        vm.prank(ALICE);
        advanced.setConditionalExpiry(conditionalId, expiry);

        uint64[] memory ids = new uint64[](1);
        ids[0] = conditionalId;
        IntegrationLens.ConditionalState[] memory conditionals =
            lens.conditionalStates(ids);

        assertTrue(conditionals[0].owner == ALICE, "conditional owner");
        assertEq(uint256(conditionals[0].lots), 25, "conditional lots");
        assertEq(uint256(conditionals[0].expiry), uint256(expiry), "conditional expiry");
        assertEq(uint256(conditionals[0].limitTick), 99, "conditional limit");

        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: IOrderBookCore.Side.Ask,
            tick: 110,
            lots: 12
        });
        vm.prank(ALICE);
        marketMaker.batchReplaceQuotes(updates);

        (uint128 managedShares, uint32 managedGeneration) =
            marketMaker.managedQuote(ALICE, IOrderBookCore.Side.Ask, 110);

        assertTrue(managedShares != 0, "managed shares missing");
        (, , uint32 generation) =
            core.pools(IOrderBookCore.Side.Ask, 110);
        assertEq(uint256(managedGeneration), uint256(generation), "managed generation");
    }

    function testLensReadsTrailingStateAndAccountSummary() public {
        vm.prank(ALICE);
        uint64 trailingId = advanced.placeTrailingOrder(
            IOrderBookCore.Side.Ask,
            10,
            90,
            20,
            IOrderBookCore.FillPolicy.IOC,
            false
        );
        uint64 expiry = uint64(block.timestamp + 600);
        vm.prank(ALICE);
        advanced.setTrailingExpiry(trailingId, expiry);

        uint64[] memory ids = new uint64[](1);
        ids[0] = trailingId;
        IntegrationLens.TrailingState[] memory trailing = lens.trailingStates(ids);
        assertTrue(trailing[0].order.owner == ALICE, "trailing owner");
        assertEq(uint256(trailing[0].order.lots), 20, "trailing lots");
        assertEq(uint256(trailing[0].expiry), uint256(expiry), "trailing expiry");

        IntegrationLens.AccountState memory account = lens.accountState(ALICE);
        assertEq(uint256(account.activeAdvancedCount), 1, "advanced count");
        assertEq(uint256(account.activeQuoteCount), 0, "quote count");
        assertTrue(account.portfolioController == address(0), "unexpected portfolio mode");
    }

    function testLensRejectsOversizedDepthScanRange() public {
        (bool ok,) = address(lens).call(
            abi.encodeCall(
                lens.depthInRange,
                (IOrderBookCore.Side.Bid, 0, 256, 1)
            )
        );
        assertTrue(!ok, "oversized depth scan accepted");
    }

    function testLensRejectsOversizedBatch() public {
        IntegrationLens.TickKey[] memory keys =
            new IntegrationLens.TickKey[](lens.MAX_BATCH() + 1);

        (bool ok,) = address(lens).call(
            abi.encodeCall(lens.poolStates, (keys))
        );
        assertTrue(!ok, "oversized lens batch accepted");
    }

    function _position(address account) internal view returns (int80 position) {
        (position,,) = core.accountRisk(account);
    }
}

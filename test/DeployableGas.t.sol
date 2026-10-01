// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract DeployableGasTest is TestBase {
    event BatchGasMeasured(uint256 batchGas, uint256 separateGas);
    event BatchCancelGasMeasured(uint256 batchCancelGas);
    event BatchScaleGasMeasured(uint256 levels, uint256 gasUsed);
    event PackedBatchMeasured(uint256 typedCalldataBytes, uint256 packedCalldataBytes, uint256 gasUsed);
    event FeeGasMeasured(uint256 zeroFeeGas, uint256 feeGas, uint256 overhead);
    OrderBookCore internal core;
    AdvancedOrderModule internal module;
    MarketMakerModule internal marketMaker;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCore(address(token), address(oracle), 40, 1_000, 0, 0);
        module = new AdvancedOrderModule(address(core), address(oracle));
        marketMaker = new MarketMakerModule(address(core), address(module));
        core.configureAdvancedModule(address(module));
        module.configureMarketMakerModule(address(marketMaker));

        token.mint(address(this), 1_000_000);
        token.approve(address(core), type(uint256).max);
        core.depositCollateral(1_000_000);
    }

    function testGas_FeeEnabledTakeOverheadIsBounded() public {
        MockERC20 zeroToken = new MockERC20();
        MockERC20 feeToken = new MockERC20();

        OrderBookCore zeroFeeCore =
            new OrderBookCore(address(zeroToken), address(oracle), 40, 1_000, 0, 0);
        OrderBookCore feeCore =
            new OrderBookCore(address(feeToken), address(oracle), 40, 1_000, 10, 5);

        address maker = address(0xB0B);
        address taker = address(0xA11CE);

        _fundCore(zeroFeeCore, zeroToken, maker, 1_000_000);
        _fundCore(zeroFeeCore, zeroToken, taker, 1_000_000);
        _fundCore(feeCore, feeToken, maker, 1_000_000);
        _fundCore(feeCore, feeToken, taker, 1_000_000);

        vm.prank(maker);
        zeroFeeCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(maker);
        feeCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        // Warm both protocol-fee and maker-rebate reserve slots so the measured
        // path reflects recurring fee-accounting cost rather than first-write cost.
        vm.prank(taker);
        zeroFeeCore.take(
            IOrderBookCore.Side.Bid, 100, 20, IOrderBookCore.FillPolicy.IOC
        );
        vm.prank(taker);
        feeCore.take(
            IOrderBookCore.Side.Bid, 100, 20, IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(taker);
        uint256 g0 = gasleft();
        zeroFeeCore.take(
            IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC
        );
        uint256 zeroFeeGas = g0 - gasleft();

        vm.prank(taker);
        g0 = gasleft();
        feeCore.take(
            IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC
        );
        uint256 feeGas = g0 - gasleft();

        uint256 overhead = feeGas > zeroFeeGas ? feeGas - zeroFeeGas : 0;
        emit FeeGasMeasured(zeroFeeGas, feeGas, overhead);

        assertTrue(feeGas < zeroFeeGas + 20_000, "recurring fee overhead too high");
    }

    function testGas_BatchReplaceFourManagedQuotesIsBoundedAndCheaperThanSeparateCalls()
        public
    {
        MarketMakerModule.QuoteUpdate[] memory initial =
            new MarketMakerModule.QuoteUpdate[](4);
        initial[0] = _update(IOrderBookCore.Side.Bid, 94, 40);
        initial[1] = _update(IOrderBookCore.Side.Bid, 95, 50);
        initial[2] = _update(IOrderBookCore.Side.Ask, 105, 60);
        initial[3] = _update(IOrderBookCore.Side.Ask, 106, 70);
        marketMaker.batchReplaceQuotes(initial);

        MarketMakerModule.QuoteUpdate[] memory one =
            new MarketMakerModule.QuoteUpdate[](1);

        uint256 separateGas;
        one[0] = _update(IOrderBookCore.Side.Bid, 94, 41);
        uint256 g0 = gasleft();
        marketMaker.batchReplaceQuotes(one);
        separateGas += g0 - gasleft();

        one[0] = _update(IOrderBookCore.Side.Bid, 95, 51);
        g0 = gasleft();
        marketMaker.batchReplaceQuotes(one);
        separateGas += g0 - gasleft();

        one[0] = _update(IOrderBookCore.Side.Ask, 105, 61);
        g0 = gasleft();
        marketMaker.batchReplaceQuotes(one);
        separateGas += g0 - gasleft();

        one[0] = _update(IOrderBookCore.Side.Ask, 106, 71);
        g0 = gasleft();
        marketMaker.batchReplaceQuotes(one);
        separateGas += g0 - gasleft();

        MarketMakerModule.QuoteUpdate[] memory batch =
            new MarketMakerModule.QuoteUpdate[](4);
        batch[0] = _update(IOrderBookCore.Side.Bid, 94, 42);
        batch[1] = _update(IOrderBookCore.Side.Bid, 95, 52);
        batch[2] = _update(IOrderBookCore.Side.Ask, 105, 62);
        batch[3] = _update(IOrderBookCore.Side.Ask, 106, 72);

        uint256 g1 = gasleft();
        marketMaker.batchReplaceQuotes(batch);
        uint256 batchGas = g1 - gasleft();

        emit BatchGasMeasured(batchGas, separateGas);
        assertTrue(batchGas < separateGas, "batch replacement lost gas advantage");
        assertTrue(batchGas < 1_000_000, "four-level batch replacement gas ceiling exceeded");
    }

    function testGas_ProfileFourSeparateManagedQuoteReplaces() public {
        MarketMakerModule.QuoteUpdate[] memory initial =
            new MarketMakerModule.QuoteUpdate[](4);
        initial[0] = _update(IOrderBookCore.Side.Bid, 94, 40);
        initial[1] = _update(IOrderBookCore.Side.Bid, 95, 50);
        initial[2] = _update(IOrderBookCore.Side.Ask, 105, 60);
        initial[3] = _update(IOrderBookCore.Side.Ask, 106, 70);
        marketMaker.batchReplaceQuotes(initial);

        MarketMakerModule.QuoteUpdate[] memory one =
            new MarketMakerModule.QuoteUpdate[](1);

        one[0] = _update(IOrderBookCore.Side.Bid, 94, 42);
        marketMaker.batchReplaceQuotes(one);
        one[0] = _update(IOrderBookCore.Side.Bid, 95, 52);
        marketMaker.batchReplaceQuotes(one);
        one[0] = _update(IOrderBookCore.Side.Ask, 105, 62);
        marketMaker.batchReplaceQuotes(one);
        one[0] = _update(IOrderBookCore.Side.Ask, 106, 72);
        marketMaker.batchReplaceQuotes(one);
    }

    function testGas_ProfileOneBatchFourManagedQuoteReplaces() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](4);
        updates[0] = _update(IOrderBookCore.Side.Bid, 94, 40);
        updates[1] = _update(IOrderBookCore.Side.Bid, 95, 50);
        updates[2] = _update(IOrderBookCore.Side.Ask, 105, 60);
        updates[3] = _update(IOrderBookCore.Side.Ask, 106, 70);
        marketMaker.batchReplaceQuotes(updates);

        updates[0].lots = 42;
        updates[1].lots = 52;
        updates[2].lots = 62;
        updates[3].lots = 72;
        marketMaker.batchReplaceQuotes(updates);
    }

    function testGas_BatchRefreshOneLevel() public {
        uint256 used = _profileBatchRefresh(1);
        emit BatchScaleGasMeasured(1, used);
        assertTrue(used < 400_000, "one-level refresh gas ceiling exceeded");
    }

    function testGas_BatchRefreshFourLevels() public {
        uint256 used = _profileBatchRefresh(4);
        emit BatchScaleGasMeasured(4, used);
        assertTrue(used < 900_000, "four-level refresh gas ceiling exceeded");
    }

    function testGas_BatchRefreshEightLevels() public {
        uint256 used = _profileBatchRefresh(8);
        emit BatchScaleGasMeasured(8, used);
        assertTrue(used < 1_600_000, "eight-level refresh gas ceiling exceeded");
    }

    function testGas_BatchRefreshSixteenLevels() public {
        uint256 used = _profileBatchRefresh(16);
        emit BatchScaleGasMeasured(16, used);
        assertTrue(used < 3_000_000, "sixteen-level refresh gas ceiling exceeded");
    }

    function testGas_PackedSixteenLevelRefreshAndCalldataSize() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](16);

        for (uint256 i; i < 16; ++i) {
            bool bid = i < 8;
            updates[i] = _update(
                bid ? IOrderBookCore.Side.Bid : IOrderBookCore.Side.Ask,
                bid ? uint16(92 + i) : uint16(101 + (i - 8)),
                uint96(20 + i)
            );
        }

        marketMaker.batchReplaceQuotes(updates);

        for (uint256 i; i < 16; ++i) updates[i].lots += 1;

        bytes memory packed = _packUpdates(updates);
        bytes memory typedCall =
            abi.encodeCall(marketMaker.batchReplaceQuotes, (updates));
        bytes memory packedCall =
            abi.encodeCall(marketMaker.batchReplaceQuotesPacked, (packed));

        uint256 g0 = gasleft();
        marketMaker.batchReplaceQuotesPacked(packed);
        uint256 used = g0 - gasleft();

        emit PackedBatchMeasured(typedCall.length, packedCall.length, used);

        assertEq(typedCall.length, 1_604, "typed calldata length");
        assertEq(packedCall.length, 324, "packed calldata length");
        assertTrue(
            packedCall.length * 4 < typedCall.length,
            "packed calldata did not shrink by at least 75%"
        );
        assertTrue(used < 2_500_000, "packed sixteen-level refresh gas ceiling exceeded");
    }

    function testGas_BatchCancelFourManagedQuotesIsBounded() public {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](4);
        updates[0] = _update(IOrderBookCore.Side.Bid, 94, 40);
        updates[1] = _update(IOrderBookCore.Side.Bid, 95, 50);
        updates[2] = _update(IOrderBookCore.Side.Ask, 105, 60);
        updates[3] = _update(IOrderBookCore.Side.Ask, 106, 70);
        marketMaker.batchReplaceQuotes(updates);

        for (uint256 i; i < updates.length; ++i) {
            updates[i].lots = 0;
        }

        uint256 g0 = gasleft();
        marketMaker.batchReplaceQuotes(updates);
        uint256 used = g0 - gasleft();

        emit BatchCancelGasMeasured(used);
        assertTrue(used < 700_000, "four-level batch cancel gas ceiling exceeded");
    }

    function _profileBatchRefresh(uint256 levels) internal returns (uint256 used) {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](levels);

        uint256 bidLevels = (levels + 1) / 2;
        for (uint256 i; i < levels; ++i) {
            bool bid = i < bidLevels;
            uint16 tick = bid
                ? uint16(100 - bidLevels + i)
                : uint16(101 + (i - bidLevels));
            updates[i] = _update(
                bid ? IOrderBookCore.Side.Bid : IOrderBookCore.Side.Ask,
                tick,
                uint96(20 + i)
            );
        }

        marketMaker.batchReplaceQuotes(updates);

        for (uint256 i; i < levels; ++i) {
            updates[i].lots += 1;
        }

        uint256 g0 = gasleft();
        marketMaker.batchReplaceQuotes(updates);
        used = g0 - gasleft();
    }

    function _fundCore(
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

    function _update(IOrderBookCore.Side side, uint16 tick, uint96 lots)
        internal
        pure
        returns (MarketMakerModule.QuoteUpdate memory update)
    {
        update = MarketMakerModule.QuoteUpdate({
            side: side,
            tick: tick,
            lots: lots
        });
    }
}

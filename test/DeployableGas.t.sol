// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract DeployableGasTest is TestBase {
    event BatchGasMeasured(uint256 batchGas, uint256 separateGas);
    event BatchCancelGasMeasured(uint256 batchCancelGas);
    OrderBookCore internal core;
    AdvancedOrderModule internal module;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCore(address(token), address(oracle), 40, 1_000);
        module = new AdvancedOrderModule(address(core), address(oracle));
        core.configureAdvancedModule(address(module));

        token.mint(address(this), 1_000_000);
        token.approve(address(core), type(uint256).max);
        core.depositCollateral(1_000_000);
    }

    function testGas_BatchReplaceFourManagedQuotesIsBoundedAndCheaperThanSeparateCalls()
        public
    {
        AdvancedOrderModule.QuoteUpdate[] memory initial =
            new AdvancedOrderModule.QuoteUpdate[](4);
        initial[0] = _update(IOrderBookCore.Side.Bid, 94, 40);
        initial[1] = _update(IOrderBookCore.Side.Bid, 95, 50);
        initial[2] = _update(IOrderBookCore.Side.Ask, 105, 60);
        initial[3] = _update(IOrderBookCore.Side.Ask, 106, 70);
        module.batchReplaceQuotes(initial);

        AdvancedOrderModule.QuoteUpdate[] memory one =
            new AdvancedOrderModule.QuoteUpdate[](1);

        uint256 separateGas;
        one[0] = _update(IOrderBookCore.Side.Bid, 94, 41);
        uint256 g0 = gasleft();
        module.batchReplaceQuotes(one);
        separateGas += g0 - gasleft();

        one[0] = _update(IOrderBookCore.Side.Bid, 95, 51);
        g0 = gasleft();
        module.batchReplaceQuotes(one);
        separateGas += g0 - gasleft();

        one[0] = _update(IOrderBookCore.Side.Ask, 105, 61);
        g0 = gasleft();
        module.batchReplaceQuotes(one);
        separateGas += g0 - gasleft();

        one[0] = _update(IOrderBookCore.Side.Ask, 106, 71);
        g0 = gasleft();
        module.batchReplaceQuotes(one);
        separateGas += g0 - gasleft();

        AdvancedOrderModule.QuoteUpdate[] memory batch =
            new AdvancedOrderModule.QuoteUpdate[](4);
        batch[0] = _update(IOrderBookCore.Side.Bid, 94, 42);
        batch[1] = _update(IOrderBookCore.Side.Bid, 95, 52);
        batch[2] = _update(IOrderBookCore.Side.Ask, 105, 62);
        batch[3] = _update(IOrderBookCore.Side.Ask, 106, 72);

        uint256 g1 = gasleft();
        module.batchReplaceQuotes(batch);
        uint256 batchGas = g1 - gasleft();

        emit BatchGasMeasured(batchGas, separateGas);
        assertTrue(batchGas < separateGas, "batch replacement lost gas advantage");
        assertTrue(batchGas < 1_000_000, "four-level batch replacement gas ceiling exceeded");
    }

    function testGas_ProfileFourSeparateManagedQuoteReplaces() public {
        AdvancedOrderModule.QuoteUpdate[] memory initial =
            new AdvancedOrderModule.QuoteUpdate[](4);
        initial[0] = _update(IOrderBookCore.Side.Bid, 94, 40);
        initial[1] = _update(IOrderBookCore.Side.Bid, 95, 50);
        initial[2] = _update(IOrderBookCore.Side.Ask, 105, 60);
        initial[3] = _update(IOrderBookCore.Side.Ask, 106, 70);
        module.batchReplaceQuotes(initial);

        AdvancedOrderModule.QuoteUpdate[] memory one =
            new AdvancedOrderModule.QuoteUpdate[](1);

        one[0] = _update(IOrderBookCore.Side.Bid, 94, 42);
        module.batchReplaceQuotes(one);
        one[0] = _update(IOrderBookCore.Side.Bid, 95, 52);
        module.batchReplaceQuotes(one);
        one[0] = _update(IOrderBookCore.Side.Ask, 105, 62);
        module.batchReplaceQuotes(one);
        one[0] = _update(IOrderBookCore.Side.Ask, 106, 72);
        module.batchReplaceQuotes(one);
    }

    function testGas_ProfileOneBatchFourManagedQuoteReplaces() public {
        AdvancedOrderModule.QuoteUpdate[] memory updates =
            new AdvancedOrderModule.QuoteUpdate[](4);
        updates[0] = _update(IOrderBookCore.Side.Bid, 94, 40);
        updates[1] = _update(IOrderBookCore.Side.Bid, 95, 50);
        updates[2] = _update(IOrderBookCore.Side.Ask, 105, 60);
        updates[3] = _update(IOrderBookCore.Side.Ask, 106, 70);
        module.batchReplaceQuotes(updates);

        updates[0].lots = 42;
        updates[1].lots = 52;
        updates[2].lots = 62;
        updates[3].lots = 72;
        module.batchReplaceQuotes(updates);
    }

    function testGas_BatchCancelFourManagedQuotesIsBounded() public {
        AdvancedOrderModule.QuoteUpdate[] memory updates =
            new AdvancedOrderModule.QuoteUpdate[](4);
        updates[0] = _update(IOrderBookCore.Side.Bid, 94, 40);
        updates[1] = _update(IOrderBookCore.Side.Bid, 95, 50);
        updates[2] = _update(IOrderBookCore.Side.Ask, 105, 60);
        updates[3] = _update(IOrderBookCore.Side.Ask, 106, 70);
        module.batchReplaceQuotes(updates);

        for (uint256 i; i < updates.length; ++i) {
            updates[i].lots = 0;
        }

        uint256 g0 = gasleft();
        module.batchReplaceQuotes(updates);
        uint256 used = g0 - gasleft();

        emit BatchCancelGasMeasured(used);
        assertTrue(used < 700_000, "four-level batch cancel gas ceiling exceeded");
    }

    function _update(IOrderBookCore.Side side, uint16 tick, uint96 lots)
        internal
        pure
        returns (AdvancedOrderModule.QuoteUpdate memory update)
    {
        update = AdvancedOrderModule.QuoteUpdate({
            side: side,
            tick: tick,
            lots: lots
        });
    }
}

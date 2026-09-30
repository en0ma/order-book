// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProRataOrderBook} from "../src/ProRataOrderBook.sol";
import {TestBase} from "./TestBase.sol";

contract GasTest is TestBase {
    function testGas_FillCostIsIndependentOfMakerCount() public {
        ProRataOrderBook oneMaker = new ProRataOrderBook();
        ProRataOrderBook manyMakers = new ProRataOrderBook();

        vm.prank(address(0x1));
        oneMaker.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, 6_400);

        for (uint160 i = 1; i <= 64; ++i) {
            vm.prank(address(0x1000 + i));
            manyMakers.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, 100);
        }

        uint256 g0 = gasleft();
        oneMaker.take(
            ProRataOrderBook.Side.Bid, 10_000, 3_200, ProRataOrderBook.FillPolicy.IOC
        );
        uint256 oneMakerGas = g0 - gasleft();

        uint256 g1 = gasleft();
        manyMakers.take(
            ProRataOrderBook.Side.Bid, 10_000, 3_200, ProRataOrderBook.FillPolicy.IOC
        );
        uint256 manyMakerGas = g1 - gasleft();

        uint256 diff =
            oneMakerGas > manyMakerGas ? oneMakerGas - manyMakerGas : manyMakerGas - oneMakerGas;

        assertTrue(diff < 20_000, "fill gas unexpectedly scales with maker count");
        assertTrue(manyMakerGas < 250_000, "single-tick fill gas ceiling exceeded");
    }

    function testGas_CancelIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();
        address maker = address(0xBEEF);

        vm.prank(maker);
        uint128 shares = book.addLiquidity(ProRataOrderBook.Side.Bid, 20_000, 10_000);

        vm.prank(maker);
        uint256 g0 = gasleft();
        book.removeShares(ProRataOrderBook.Side.Bid, 20_000, shares);
        uint256 used = g0 - gasleft();

        assertTrue(used < 220_000, "cancel gas ceiling exceeded");
    }

    function testGas_AddAtExistingTickIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();

        vm.prank(address(0x1));
        book.addLiquidity(ProRataOrderBook.Side.Ask, 30_000, 1_000);

        vm.prank(address(0x2));
        uint256 g0 = gasleft();
        book.addLiquidity(ProRataOrderBook.Side.Ask, 30_000, 1_000);
        uint256 used = g0 - gasleft();

        assertTrue(used < 220_000, "maker add gas ceiling exceeded");
    }
}

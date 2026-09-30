// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProRataOrderBook} from "../src/ProRataOrderBook.sol";
import {TestBase} from "./TestBase.sol";

contract MainnetForkTest is TestBase {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function testMainnetForkAndOrderBookExecution() public {
        string memory rpc = vm.envString("ETH_RPC");
        vm.createSelectFork(rpc);

        assertEq(block.chainid, 1, "not mainnet");
        assertTrue(WETH.code.length > 0, "WETH missing on fork");

        ProRataOrderBook book = new ProRataOrderBook();

        vm.prank(address(0xA11CE));
        book.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, 1_000);

        uint96 filled =
            book.take(ProRataOrderBook.Side.Bid, 10_000, 250, ProRataOrderBook.FillPolicy.IOC);

        assertEq(filled, 250, "fork execution failed");
    }
}

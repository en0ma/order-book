// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProRataOrderBook} from "../src/ProRataOrderBook.sol";
import {TestBase} from "./TestBase.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MainnetForkTest is TestBase {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function testMainnetForkAndOrderBookExecution() public {
        string memory rpc = vm.envString("ETH_RPC");
        vm.createSelectFork(rpc);

        assertEq(block.chainid, 1, "not mainnet");
        assertTrue(WETH.code.length > 0, "WETH missing on fork");

        ProRataOrderBook book = new ProRataOrderBook();
        MockMarkOracle oracle = new MockMarkOracle(10_000);
        book.configureSettlement(WETH, address(oracle));

        vm.deal(address(this), 1 ether);
        IWETH(WETH).deposit{value: 1 ether}();
        IWETH(WETH).approve(address(book), type(uint256).max);

        book.depositCollateral(0.5 ether);
        assertEq(IWETH(WETH).balanceOf(address(book)), 0.5 ether, "real WETH custody failed");

        book.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, 1_000);

        uint96 filled =
            book.take(ProRataOrderBook.Side.Bid, 10_000, 250, ProRataOrderBook.FillPolicy.IOC);

        assertEq(filled, 250, "fork execution failed");
    }
}

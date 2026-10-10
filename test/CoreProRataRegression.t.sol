// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract CoreProRataRegressionTest is TestBase {
    function testEqualMakersReceiveEqualExecutedLotsRegardlessOfSettlementOrder() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        OrderBookCore core = new OrderBookCore(address(token), address(oracle), 30, 1000, 0, 0);
        address a = address(0xA11CE);
        address b = address(0xB0B);
        address taker = address(0xCAFE);
        address[3] memory actors = [a,b,taker];
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], 1_000_000);
            vm.prank(actors[i]); token.approve(address(core), type(uint256).max);
            vm.prank(actors[i]); core.depositCollateral(1_000_000);
        }
        vm.prank(a); core.addLiquidity(IOrderBookCore.Side.Ask, 100, 20);
        vm.prank(b); core.addLiquidity(IOrderBookCore.Side.Ask, 100, 20);
        vm.prank(taker);
        uint96 filled = core.take(IOrderBookCore.Side.Bid, 100, 20, IOrderBookCore.FillPolicy.IOC);
        assertEq(uint256(filled), 20, "taker fill mismatch");
        vm.prank(b); core.settle(IOrderBookCore.Side.Ask, 100);
        vm.prank(a); core.settle(IOrderBookCore.Side.Ask, 100);
        (int80 aPosition,,) = core.accountRisk(a);
        (int80 bPosition,,) = core.accountRisk(b);
        (int80 takerPosition,,) = core.accountRisk(taker);
        assertEq(int256(aPosition), -10, "first maker share drift");
        assertEq(int256(bPosition), -10, "second maker share drift");
        assertEq(int256(takerPosition), 20, "net exposure drift");
    }
}

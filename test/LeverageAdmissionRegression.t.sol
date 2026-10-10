// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract LeverageAdmissionRegressionTest is TestBase {
    function testFuzz_UndercollateralizedQuoteCannotCreateFreeRisk(uint96 rawLots) public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        OrderBookCore core = new OrderBookCore(address(token), address(oracle), 25, 1000, 0, 0);
        address trader = address(0xA11CE);
        token.mint(trader, 1);
        vm.prank(trader); token.approve(address(core), type(uint256).max);
        vm.prank(trader); core.depositCollateral(1);
        uint96 lots = uint96(uint256(rawLots) % 50_000 + 100);
        vm.prank(trader);
        (bool ok,) = address(core).call(abi.encodeCall(core.addLiquidity,
            (IOrderBookCore.Side.Ask, uint16(100), lots)));
        assertTrue(!ok, "undercollateralized exposure admitted");
        assertEq(uint256(core.activeQuoteCount(trader)), 0, "failed admission left quote");
        (int80 position, int80 low, int80 high) = core.accountRisk(trader);
        assertEq(int256(position), 0, "failed admission changed position");
        assertEq(int256(low), 0, "failed admission changed risk low");
        assertEq(int256(high), 0, "failed admission changed risk high");
        assertEq(token.balanceOf(address(core)), 1, "failed admission moved custody");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract LiquidationHealthRegressionTest is TestBase {
    function testOpenMakerQuoteBlocksPrematureLiquidationOfFlatAccount() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        OrderBookCore core = new OrderBookCore(address(token), address(oracle), 30, 1000, 0, 0);
        AdvancedOrderModule advanced = new AdvancedOrderModule(address(core), address(oracle));
        LiquidationModule liquidation = new LiquidationModule(address(core), address(advanced), address(0), 500);
        core.configureAdvancedModule(address(advanced));
        advanced.configureLiquidationModule(address(liquidation));
        address trader = address(0xA11CE);
        token.mint(trader, 100_000);
        vm.prank(trader); token.approve(address(core), type(uint256).max);
        vm.prank(trader); core.depositCollateral(100_000);
        assertTrue(!liquidation.isLiquidatable(trader), "flat funded account liquidatable");
        vm.prank(trader); core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);
        assertTrue(!liquidation.isLiquidatable(trader), "open quote must block liquidation");
        assertEq(liquidation.terminalBadDebt(trader), 0, "open quote reported terminal debt");
        (uint128 shares,,) = core.quotes(trader, IOrderBookCore.Side.Ask, 100);
        vm.prank(trader); core.removeShares(IOrderBookCore.Side.Ask, 100, shares);
        assertTrue(!liquidation.isLiquidatable(trader), "flat cancelled account liquidatable");
    }
}

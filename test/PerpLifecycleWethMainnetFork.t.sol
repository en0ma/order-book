// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IntegrationLens} from "../src/deployable/IntegrationLens.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
interface IWrappedEther {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns(bool);
    function balanceOf(address) external view returns(uint256);
}
contract PerpLifecycleWethMainnetForkTest is TestBase {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MAKER = address(0xB0B);
    address constant TRADER = address(0xA11CE);
    address constant OTHER_MAKER = address(0xCAFE);
    function testMainnetForkRealWethOpenFundCloseSettleWithdraw() public {
        vm.createSelectFork(vm.envString("ETH_RPC"));
        assertEq(block.chainid, 1, "requires Ethereum mainnet fork");
        SegmentTreeExtremaOracle oracle = new SegmentTreeExtremaOracle(address(this), 100, 3600);
        OrderBookCore core = new OrderBookCore(WETH, address(oracle), 30, 1000, 0, 0);
        AdvancedOrderModule advanced = new AdvancedOrderModule(address(core), address(oracle));
        MarketMakerModule mm = new MarketMakerModule(address(core), address(advanced));
        LiquidationModule liq = new LiquidationModule(address(core), address(advanced), address(0), 500);
        core.configureAdvancedModule(address(advanced));
        advanced.configureMarketMakerModule(address(mm));
        advanced.configureLiquidationModule(address(liq));
        _fund(MAKER, core);
        _fund(TRADER, core);
        _fund(OTHER_MAKER, core);
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 40);
        vm.prank(TRADER);
        assertEq(core.take(IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC), 40, "opening trade");
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);
        (int80 longPosition,,) = core.accountRisk(TRADER);
        assertEq(int256(longPosition), 40, "long entry");
        (int80 shortPosition,,) = core.accountRisk(MAKER);
        assertEq(int256(shortPosition), -40, "short counterparty");
        core.setFundingIndex(1e18);
        vm.prank(OTHER_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 40);
        vm.prank(TRADER);
        assertEq(core.take(IOrderBookCore.Side.Ask, 100, 40, IOrderBookCore.FillPolicy.IOC), 40, "closing trade");
        vm.prank(OTHER_MAKER);
        core.settle(IOrderBookCore.Side.Bid, 100);
        (longPosition,,) = core.accountRisk(TRADER);
        assertEq(int256(longPosition), 0, "position not closed");
        assertEq(IWrappedEther(WETH).balanceOf(address(core)), 3 ether, "WETH custody drift");
        vm.prank(TRADER);
        core.withdrawCollateral(1);
        assertEq(IWrappedEther(WETH).balanceOf(address(core)), 3 ether - 1, "WETH withdrawal drift");
    }
    function _fund(address account, OrderBookCore core) internal {
        vm.deal(account, 1 ether);
        vm.prank(account); IWrappedEther(WETH).deposit{value: 1 ether}();
        vm.prank(account); IWrappedEther(WETH).approve(address(core), type(uint256).max);
        vm.prank(account); core.depositCollateral(1 ether);
    }
}

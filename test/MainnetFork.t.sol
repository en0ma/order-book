// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {TestBase} from "./TestBase.sol";

interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MainnetForkTest is TestBase {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function testMainnetForkDeployableStackAndOrderBookExecution() public {
        string memory rpc = vm.envString("ETH_RPC");
        vm.createSelectFork(rpc);

        assertEq(block.chainid, 1, "not mainnet");
        assertTrue(WETH.code.length > 0, "WETH missing on fork");

        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 10_000, 3_600);
        OrderBookCore core =
            new OrderBookCore(WETH, address(oracle), 500, 1_000, 10, 5);
        AdvancedOrderModule advanced =
            new AdvancedOrderModule(address(core), address(oracle));
        MarketMakerModule marketMaker =
            new MarketMakerModule(address(core), address(advanced));
        LiquidationModule liquidation =
            new LiquidationModule(address(core), address(advanced), address(0), 500);

        core.configureAdvancedModule(address(advanced));
        advanced.configureMarketMakerModule(address(marketMaker));
        advanced.configureLiquidationModule(address(liquidation));

        _fundWithWeth(ALICE, core, 1 ether);
        _fundWithWeth(BOB, core, 1 ether);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 10_000, 1_000);

        vm.prank(BOB);
        uint96 filled =
            core.take(IOrderBookCore.Side.Bid, 10_000, 250, IOrderBookCore.FillPolicy.IOC);

        assertEq(filled, 250, "fork execution failed");
        assertEq(
            IWETH(WETH).balanceOf(address(core)),
            2 ether,
            "deployable core WETH custody failed"
        );

        (int80 takerPosition,,) = core.accountRisk(BOB);
        assertEq(int256(takerPosition), 250, "deployable taker accounting failed");
        assertTrue(address(core.markOracle()) == address(oracle), "oracle wiring mismatch");
        assertTrue(core.advancedModule() == address(advanced), "advanced module wiring mismatch");
        assertTrue(
            advanced.marketMakerModule() == address(marketMaker),
            "market-maker module wiring mismatch"
        );
        assertTrue(
            advanced.liquidationModule() == address(liquidation),
            "liquidation module wiring mismatch"
        );
    }

    function _fundWithWeth(address account, OrderBookCore core, uint256 amount) internal {
        vm.deal(account, amount);
        vm.prank(account);
        IWETH(WETH).deposit{value: amount}();
        vm.prank(account);
        IWETH(WETH).approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }
}

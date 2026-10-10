// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

// Test-only storage harness constructs otherwise difficult-to-reach distressed
// states; the deployed liquidation policy and execution contracts remain real.
contract LiquidationHealthCoreHarness is OrderBookCore {
    constructor(address token, address oracle)
        OrderBookCore(token, oracle, 30, 1000, 0, 0) {}

    function setDistressedState(address trader, int80 position, int256 pnl) external {
        accountRisk[trader] = AccountRisk(position, position, position);
        tradeCashflow[trader] = pnl;
    }
}

contract LiquidationHealthRegressionTest is TestBase {
    function testOpenOrdersGateLiquidationAndTerminalDebtOnDistressedAccounts() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        LiquidationHealthCoreHarness core =
            new LiquidationHealthCoreHarness(address(token), address(oracle));
        AdvancedOrderModule advanced = new AdvancedOrderModule(address(core), address(oracle));
        LiquidationModule liquidation =
            new LiquidationModule(address(core), address(advanced), address(0), 500);
        core.configureAdvancedModule(address(advanced));
        advanced.configureLiquidationModule(address(liquidation));

        address underwater = address(0xA11CE);
        address insolvent = address(0xB0B);
        address[2] memory accounts = [underwater, insolvent];
        for (uint256 i; i < accounts.length; ++i) {
            token.mint(accounts[i], 100_000);
            vm.prank(accounts[i]);
            token.approve(address(core), type(uint256).max);
            vm.prank(accounts[i]);
            core.depositCollateral(100_000);
            vm.prank(accounts[i]);
            core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);
        }

        // Without the live-order guard, both policies would declare distress.
        core.setDistressedState(underwater, 100, -200_000);
        core.setDistressedState(insolvent, 0, -200_000);
        assertTrue(core.accountEquity(underwater) < 0, "missing underwater state");
        assertTrue(core.accountEquity(insolvent) < 0, "missing terminal debt state");
        assertTrue(!liquidation.isLiquidatable(underwater), "live quote bypassed liquidation gate");
        assertEq(liquidation.terminalBadDebt(insolvent), 0, "live quote bypassed debt gate");

        // Cancel in a healthy state, then recreate the exact distressed balances
        // without a live order: the policy must now recognize the underlying risk.
        for (uint256 i; i < accounts.length; ++i) {
            core.setDistressedState(accounts[i], 0, 0);
            (uint128 shares,,) = core.quotes(accounts[i], IOrderBookCore.Side.Ask, 100);
            vm.prank(accounts[i]);
            core.removeShares(IOrderBookCore.Side.Ask, 100, shares);
        }
        core.setDistressedState(underwater, 100, -200_000);
        core.setDistressedState(insolvent, 0, -200_000);
        assertTrue(liquidation.isLiquidatable(underwater), "distressed order-free position not liquidatable");
        assertTrue(liquidation.terminalBadDebt(insolvent) > 0, "order-free terminal debt not detected");
    }
}

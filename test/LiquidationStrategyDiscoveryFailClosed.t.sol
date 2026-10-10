// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {LiquidationPolicy} from "../src/deployable/LiquidationPolicy.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

// The real core's state is initialized directly to model otherwise unreachable
// post-loss accounts without depending on a specific matching route.
contract StrategyDiscoveryCoreHarness is OrderBookCore {
    constructor(address token, address oracle)
        OrderBookCore(token, oracle, 30, 1_000, 0, 0) {}

    function setRiskAndCash(address account, int80 position, int256 cash) external {
        accountRisk[account] = AccountRisk(position, position, position);
        tradeCashflow[account] = cash;
    }
}

// Adversarial gateway with a valid advanced-order counter but no strategy
// discovery selector. Models an ABI mismatch or faulty strategy integration.
contract MissingStrategyDiscoveryGateway {
    function activeAdvancedOrders(address) external pure returns (uint32) {
        return 0;
    }
}

contract LiquidationStrategyDiscoveryFailClosedTest is TestBase {
    function testMissingDiscoveryDoesNotAuthorizeDistressedLiquidationOrBadDebt() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        StrategyDiscoveryCoreHarness core =
            new StrategyDiscoveryCoreHarness(address(token), address(oracle));
        MissingStrategyDiscoveryGateway brokenGateway =
            new MissingStrategyDiscoveryGateway();
        LiquidationPolicy policy =
            new LiquidationPolicy(address(core), address(brokenGateway), 500);

        address underwater = address(0xA11CE);
        address insolvent = address(0xB0B);
        core.setRiskAndCash(underwater, 100, -20_000);
        core.setRiskAndCash(insolvent, 0, -1_000);

        assertTrue(core.accountEquity(underwater) < 0, "underwater fixture not distressed");
        assertTrue(core.accountEquity(insolvent) < 0, "debt fixture not insolvent");
        assertTrue(policy.hasOpenOrders(underwater), "discovery failure treated as no orders");
        assertTrue(!policy.isLiquidatable(underwater), "unknown orders admitted liquidation");
        assertEq(policy.terminalBadDebt(insolvent), 0, "unknown orders authorized terminal debt");
    }

    function testActualGatewayWithNoOrdersPreservesLiquidationAndDebtClassification() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        StrategyDiscoveryCoreHarness core =
            new StrategyDiscoveryCoreHarness(address(token), address(oracle));
        AdvancedOrderModule advanced = new AdvancedOrderModule(address(core), address(oracle));
        LiquidationPolicy policy = new LiquidationPolicy(address(core), address(advanced), 500);

        address underwater = address(0xA11CE);
        address insolvent = address(0xB0B);
        core.setRiskAndCash(underwater, 100, -20_000);
        core.setRiskAndCash(insolvent, 0, -1_000);

        assertTrue(!policy.hasOpenOrders(underwater), "empty real gateway reported orders");
        assertTrue(policy.isLiquidatable(underwater), "underwater account not liquidatable");
        assertEq(policy.terminalBadDebt(insolvent), 1_000, "terminal debt classification drift");
    }
}

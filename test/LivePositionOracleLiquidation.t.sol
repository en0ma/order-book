// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {LiquidationPolicy} from "../src/deployable/LiquidationPolicy.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @dev Inject settled risk/cash to isolate oracle-dependent health from matching.
contract OracleLiquidationCoreHarness is OrderBookCore {
    constructor(address token, address oracle)
        OrderBookCore(token, oracle, 30, 1000, 0, 0) {}

    function setPositionAndCash(address account, int80 position, int256 cash) external {
        accountRisk[account] = AccountRisk(position, position, position);
        tradeCashflow[account] = cash;
    }
}

/// @notice Models a compromised/misconfigured mark oracle, NOT permissionless manipulation.
/// @dev Positions and trade cashflows are test fixtures. No actual trade or collateral extraction is claimed.
contract LivePositionOracleLiquidationTest is TestBase {
    MockERC20 internal token;
    MockMarkOracle internal oracle;
    OracleLiquidationCoreHarness internal core;
    LiquidationPolicy internal policy;
    address internal trader = address(0xA11CE);

    function setUp() public {
        token = new MockERC20();
        oracle = new MockMarkOracle(100);
        core = new OracleLiquidationCoreHarness(address(token), address(oracle));
        core.configureAccountingUnitScale(1);
        AdvancedOrderModule advanced = new AdvancedOrderModule(address(core), address(oracle));
        policy = new LiquidationPolicy(address(core), address(advanced), 500);
        token.mint(trader, 1000);
        vm.prank(trader);
        token.approve(address(core), 1000);
        vm.prank(trader);
        core.depositCollateral(1000);
    }

    function testCompromisedLowerMarkFlipsLongLiquidationEligibility() public {
        core.setPositionAndCash(trader, 100, -9800);
        assertTrue(!policy.hasOpenOrders(trader), "fixture unexpectedly has open orders");
        assertEq(core.accountEquity(trader), int256(1200), "healthy long fixture invalid");
        assertEq(policy.maintenanceRequirement(trader), 500, "healthy maintenance mismatch");
        assertTrue(!policy.isLiquidatable(trader), "healthy long was liquidatable");

        oracle.setMarkTick(90);
        assertEq(core.accountEquity(trader), int256(200), "long equity did not follow mark");
        assertEq(policy.maintenanceRequirement(trader), 450, "maintenance did not follow mark");
        assertTrue(policy.isLiquidatable(trader), "lower mark did not enable liquidation");

        oracle.setMarkTick(100);
        assertTrue(!policy.isLiquidatable(trader), "restored mark did not restore health");
        assertEq(token.balanceOf(address(core)), 1000, "mark-only change moved custody");
    }

    function testCompromisedHigherMarkFlipsShortLiquidationEligibility() public {
        core.setPositionAndCash(trader, -100, 11000);
        assertEq(core.accountEquity(trader), int256(2000), "healthy short fixture invalid");
        assertTrue(!policy.isLiquidatable(trader), "healthy short was liquidatable");

        oracle.setMarkTick(120);
        assertEq(core.accountEquity(trader), int256(0), "short equity did not follow mark");
        assertEq(policy.maintenanceRequirement(trader), 600, "short maintenance mismatch");
        assertTrue(policy.isLiquidatable(trader), "higher mark did not enable liquidation");

        oracle.setMarkTick(100);
        assertTrue(!policy.isLiquidatable(trader), "restored short mark remained liquidatable");
        assertEq(token.balanceOf(address(core)), 1000, "mark-only change moved custody");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract InsuranceBoundaryCoreHarness is OrderBookCore {
    constructor(address token, address oracle)
        OrderBookCore(token, oracle, 30, 1_000, 0, 0) {}

    // Construct insolvent states without changing the production insurance path.
    function setAccountDeficit(address account, int80 position, int256 tradePnl) external {
        accountRisk[account] = AccountRisk(position, position, position);
        tradeCashflow[account] = tradePnl;
    }
}

contract LiquidationInsuranceBoundaryTest is TestBase {
    function testInsuranceCannotCoverOpenPositionOrMoreThanTerminalDebt() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        InsuranceBoundaryCoreHarness core =
            new InsuranceBoundaryCoreHarness(address(token), address(oracle));
        AdvancedOrderModule advanced = new AdvancedOrderModule(address(core), address(oracle));
        LiquidationModule liquidation =
            new LiquidationModule(address(core), address(advanced), address(0), 500);
        core.configureAdvancedModule(address(advanced));
        advanced.configureLiquidationModule(address(liquidation));

        address funder = address(0xBEEF);
        address debtor = address(0xA11CE);
        token.mint(funder, 1_000);
        vm.prank(funder);
        token.approve(address(core), 1_000);
        vm.prank(funder);
        core.fundInsurance(1_000);
        assertEq(core.insuranceReserves(), 1_000, "insurance funding mismatch");
        assertEq(token.balanceOf(address(core)), 1_000, "insurance custody mismatch");

        core.setAccountDeficit(debtor, 1, -1_500);
        vm.prank(address(advanced));
        (bool premature,) = address(core).call(
            abi.encodeCall(core.moduleCoverBadDebt, (debtor, 1_000))
        );
        assertTrue(!premature, "open position drained insurance");
        assertEq(core.insuranceReserves(), 1_000, "rejected coverage consumed insurance");

        core.setAccountDeficit(debtor, 0, -600);
        vm.prank(address(advanced));
        uint256 first = core.moduleCoverBadDebt(debtor, 900);
        assertEq(first, 600, "coverage exceeded terminal debt");
        assertEq(core.insuranceReserves(), 400, "insurance debit mismatch");
        assertEq(core.accountEquity(debtor), 0, "terminal debtor not made whole");
        assertEq(token.balanceOf(address(core)), 1_000, "coverage changed token custody");

        vm.prank(address(advanced));
        uint256 repeated = core.moduleCoverBadDebt(debtor, 400);
        assertEq(repeated, 0, "solvent account received repeated insurance");
        assertEq(core.insuranceReserves(), 400, "repeat coverage consumed reserves");

        core.setAccountDeficit(debtor, 0, -900);
        vm.prank(address(advanced));
        uint256 second = core.moduleCoverBadDebt(debtor, 900);
        assertEq(second, 400, "insurance coverage exceeded available reserve");
        assertEq(core.insuranceReserves(), 0, "insurance not fully decremented");
        assertEq(core.accountEquity(debtor), -500, "residual debt mismatch");
        assertEq(token.balanceOf(address(core)), 1_000, "insurance coverage should be ledger-only");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PartialLiquidationLiquidityStressTest} from "./PartialLiquidationLiquidityStress.t.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

/// @notice Adversarial insurance and incentive accounting on the real liquidation route.
/// @dev The mark has been moved to 80 in the parent fixture; this does not establish
///      permissionless control over a production oracle.
contract LiquidationInsuranceCoverageAuditTest is PartialLiquidationLiquidityStressTest {
    function testFundedInsuranceCoversOnlyRealizedTerminalLoss() public {
        token.mint(address(this), 1000);
        token.approve(address(core), 1000);
        core.fundInsurance(1000);

        uint256 custody = token.balanceOf(address(core));
        uint256 protocolFees = core.protocolFeesAccrued();
        assertEq(core.insuranceReserves(), 1000, "insurance funding missing");
        assertEq(protocolFees, 0, "unexpected initial fee reserve");

        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 100);

        liquidation.configureLiquidatorReward(100);
        _liquidate(100);

        (int80 position,,) = core.accountRisk(TRADER);
        assertEq(int256(position), 0, "liquidation left exposure");
        assertEq(core.accountEquity(TRADER), int256(0), "terminal debt not covered");
        assertEq(core.insuranceReserves(), 400, "insurance spent beyond realized debt");
        assertEq(token.balanceOf(address(core)), custody, "insurance moved custody out");
        assertEq(token.balanceOf(address(this)), 0, "liquidator paid without fee reserves");
        assertEq(core.protocolFeesAccrued(), protocolFees, "fee reserve unexpectedly changed");
        assertEq(liquidation.terminalBadDebt(TRADER), 0, "terminal debt remains");
    }

    function testZeroInsuranceBalanceCannotInventBadDebtCoverageOrRewards() public {
        uint256 custody = token.balanceOf(address(core));
        liquidation.configureLiquidatorReward(100);
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 100);
        _liquidate(100);

        (int80 position,,) = core.accountRisk(TRADER);
        assertEq(int256(position), 0, "position not fully closed");
        assertEq(core.insuranceReserves(), 0, "insurance was invented");
        assertEq(core.accountEquity(TRADER), int256(-600), "uninsured terminal loss changed");
        assertEq(liquidation.terminalBadDebt(TRADER), 600, "terminal debt not recorded");
        assertEq(token.balanceOf(address(core)), custody, "unfunded close changed custody");
        assertEq(token.balanceOf(address(this)), 0, "liquidator paid from nonexistent fees");
    }
}

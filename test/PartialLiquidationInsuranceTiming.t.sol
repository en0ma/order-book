// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PartialLiquidationLiquidityStressTest} from "./PartialLiquidationLiquidityStress.t.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

/// @notice Insurance must only cover terminal bad debt after a position is flat.
/// @dev Exercises the production matching and liquidation modules with controlled test marks.
contract PartialLiquidationInsuranceTimingTest is PartialLiquidationLiquidityStressTest {
    function testInsuranceIsNotSpentUntilPositionFullyClosed() public {
        token.mint(address(this), 1000);
        token.approve(address(core), 1000);
        core.fundInsurance(1000);

        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 40);

        uint256 custodyBefore = token.balanceOf(address(core));
        uint256 feeBefore = core.protocolFeesAccrued();
        _liquidate(40);
        (int80 remaining,,) = core.accountRisk(TRADER);
        assertEq(int256(remaining), 60, "partial fill unexpectedly closed position");
        assertEq(core.insuranceReserves(), 1000, "insurance paid before terminal close");
        assertEq(token.balanceOf(address(core)), custodyBefore, "partial fill moved custody");
        assertEq(core.protocolFeesAccrued(), feeBefore, "partial fill altered fees");

        // A zero-fill retry must not unlock insurance coverage.
        _liquidate(0);
        assertEq(core.insuranceReserves(), 1000, "empty retry paid insurance");

        vm.prank(EXIT_MAKER);
        core.settle(IOrderBookCore.Side.Bid, 80);
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 60);
        _liquidate(60);

        (remaining,,) = core.accountRisk(TRADER);
        assertEq(int256(remaining), 0, "full close left exposure");
        assertEq(core.insuranceReserves(), 400, "terminal coverage amount incorrect");
        assertEq(core.accountEquity(TRADER), int256(0), "terminal loss not covered");
        assertEq(liquidation.terminalBadDebt(TRADER), 0, "terminal debt not settled");
        assertEq(token.balanceOf(address(core)), custodyBefore, "insurance altered custody");
    }
}

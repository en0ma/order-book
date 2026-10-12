// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PartialLiquidationLiquidityStressTest} from "./PartialLiquidationLiquidityStress.t.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

/// @notice Insurance shortfall after a real full-position liquidation.
/// @dev This fixture uses a controlled mark decline, not a demonstrated oracle exploit.
contract PartialInsuranceShortfallTest is PartialLiquidationLiquidityStressTest {
    function testPartialInsuranceCannotEraseUnfundedTerminalDebt() public {
        token.mint(address(this), 200);
        token.approve(address(core), 200);
        core.fundInsurance(200);
        assertEq(core.insuranceReserves(), 200, "shortfall reserve not funded");

        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 100);

        uint256 custodyBefore = token.balanceOf(address(core));
        uint256 feesBefore = core.protocolFeesAccrued();

        _liquidate(100);

        (int80 remaining,,) = core.accountRisk(TRADER);
        assertEq(int256(remaining), 0, "terminal position not closed");
        assertEq(core.insuranceReserves(), 0, "shortfall did not consume available insurance");
        assertEq(core.accountEquity(TRADER), int256(-400), "uninsured loss was not preserved");
        assertEq(liquidation.terminalBadDebt(TRADER), 400, "residual bad debt was hidden");
        assertEq(token.balanceOf(address(core)), custodyBefore, "insurance moved custody");
        assertEq(core.protocolFeesAccrued(), feesBefore, "coverage changed accrued fees");

        // Once flat, an additional liquidation must fail instead of
        // attempting to cover the same residual debt from nonexistent reserves.
        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory ids = new uint64[](0);
        (bool retried,) = address(liquidation).call(
            abi.encodeCall(liquidation.liquidate, (TRADER, sides, ticks, ids, ids, ids))
        );
        assertTrue(!retried, "flat account accepted repeat liquidation");
        assertEq(liquidation.terminalBadDebt(TRADER), 400, "retry erased unpaid debt");
        assertEq(token.balanceOf(address(core)), custodyBefore, "retry changed custody");
    }
}

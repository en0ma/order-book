// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PartialLiquidationLiquidityStressTest} from "./PartialLiquidationLiquidityStress.t.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

/// @notice Additional adversarial liquidity and incentive scenarios on the real
/// liquidation/matching path, using the reusable distressed-account fixture.
contract LiquidationIncentiveFailureMatrixTest is PartialLiquidationLiquidityStressTest {
    function testEmptyBookEarnsNoLiquidatorRewardAndLeavesCustodyIntact() public {
        liquidation.configureLiquidatorReward(100);
        uint256 custody = token.balanceOf(address(core));
        uint256 liquidatorTokens = token.balanceOf(address(this));
        _liquidate(0);
        assertEq(token.balanceOf(address(this)), liquidatorTokens, "zero-fill paid reward");
        assertEq(core.protocolFeesAccrued(), 0, "empty liquidation accrued fees");
        assertEq(token.balanceOf(address(core)), custody, "empty liquidation moved custody");
        assertTrue(liquidation.isLiquidatable(TRADER), "zero-fill cured insolvency");
    }

    function testMultiTickPartialThenZeroFillThenCompleteWithNoFeeReserve() public {
        liquidation.configureLiquidatorReward(100);
        uint256 custody = token.balanceOf(address(core));
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 30);
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 79, 20);

        _liquidate(50);
        (int80 residual,,) = core.accountRisk(TRADER);
        assertEq(int256(residual), 50, "multi-tick liquidation wrong residual");
        assertEq(core.protocolFeesAccrued(), 0, "fee-free trading created protocol fees");
        assertEq(token.balanceOf(address(this)), 0, "reward paid without fee reserve");
        assertEq(token.balanceOf(address(core)), custody, "partial close moved custody");

        _liquidate(0);
        (residual,,) = core.accountRisk(TRADER);
        assertEq(int256(residual), 50, "no-liquidity retry changed position");
        assertTrue(liquidation.isLiquidatable(TRADER), "partial close skipped health check");

        vm.prank(EXIT_MAKER);
        core.settle(IOrderBookCore.Side.Bid, 80);
        vm.prank(EXIT_MAKER);
        core.settle(IOrderBookCore.Side.Bid, 79);
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 50);
        _liquidate(50);
        (residual,,) = core.accountRisk(TRADER);
        assertEq(int256(residual), 0, "final close left exposure");
        assertEq(token.balanceOf(address(core)), custody, "complete close moved custody");
        assertEq(token.balanceOf(address(this)), 0, "liquidator paid without reserves");
        assertEq(core.insuranceReserves(), 0, "empty insurance reserve changed");
    }

    function testLiquidatorRewardConfigurationCannotBeChangedAfterBootstrap() public {
        liquidation.configureLiquidatorReward(100);
        (bool again,) = address(liquidation).call(
            abi.encodeCall(liquidation.configureLiquidatorReward, (uint16(1000)))
        );
        assertTrue(!again, "liquidator reward was mutable after initialization");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PartialLiquidationLiquidityStressTest} from "./PartialLiquidationLiquidityStress.t.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

/// @notice Real Core, oracle and gateway, covering healthy-state refusal,
/// liquidation retry after missing liquidity, reward eligibility and terminal debt.
contract StandaloneLiquidationLifecycleAcceptanceTest is PartialLiquidationLiquidityStressTest {
    function testHealthyAccountCannotEnterCleanupOrReceiveReward() public {
        // Restore health with collateral rather than assuming a new oracle
        // sample removes a still-live low observation from the extrema ring.
        _deposit(TRADER, 3_000);
        assertTrue(!liquidation.isLiquidatable(TRADER), "fixture remains distressed");
        liquidation.configureLiquidatorReward(100);
        uint256 custody = token.balanceOf(address(core));
        uint256 rewardBefore = token.balanceOf(address(this));
        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory ids = new uint64[](0);
        (bool ok,) = address(liquidation).call(abi.encodeCall(
            liquidation.liquidate, (TRADER, sides, ticks, ids, ids, ids)
        ));
        assertTrue(!ok, "healthy account was liquidated");
        assertEq(token.balanceOf(address(core)), custody, "healthy refusal moved custody");
        assertEq(token.balanceOf(address(this)), rewardBefore, "healthy refusal paid reward");
    }

    function testFuzz_ZeroPartialThenTerminalCloseKeepsConservation(uint8 firstFillSeed) public {
        uint96 firstFill = uint96(uint256(firstFillSeed) % 99 + 1);
        liquidation.configureLiquidatorReward(100);
        uint256 custody = token.balanceOf(address(core));
        _liquidate(0);
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, firstFill);
        _liquidate(firstFill);
        (int80 residual,,) = core.accountRisk(TRADER);
        assertEq(int256(residual), int256(uint256(100 - firstFill)), "partial residual mismatch");
        assertEq(token.balanceOf(address(core)), custody, "partial liquidation spent custody");

        _liquidate(0);
        vm.prank(EXIT_MAKER);
        core.settle(IOrderBookCore.Side.Bid, 80);
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, uint96(100 - firstFill));
        _liquidate(uint96(100 - firstFill));
        (residual,,) = core.accountRisk(TRADER);
        assertEq(int256(residual), 0, "terminal close left position");
        assertEq(token.balanceOf(address(core)), custody, "terminal close moved custody");
        assertEq(token.balanceOf(address(this)), 0, "unfunded reward was paid");
        assertEq(core.insuranceReserves(), 0, "unfunded insurance was invented");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioTwoMarketFeeIsolationTest} from "./PortfolioTwoMarketFeeIsolation.t.sol";
import {PortfolioFeeSolvencyPreflight} from "../src/deployable/PortfolioFeeSolvencyPreflight.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

contract Issue203PortfolioFeeSolvencyTest is PortfolioTwoMarketFeeIsolationTest {
    function test_UnionIncludesVaultOnlyDepositorsWithoutAnyMarketActivity() public {
        PortfolioFeeSolvencyPreflight proof = new PortfolioFeeSolvencyPreflight();
        (uint256 capacity, uint256 claims, uint256 liabilities) =
            proof.conservativeCapacity(coordinator);
        assertEq(claims, 130000, "missing portfolio depositor liability");
        assertEq(liabilities, 130000, "missing portfolio liability backing");
        assertEq(capacity, 0, "unearned fee becomes withdrawable");
    }

    function testFuzz_DonationCannotCreatePortfolioDistributableFees(uint96 seed) public {
        PortfolioFeeSolvencyPreflight proof = new PortfolioFeeSolvencyPreflight();
        token.mint(address(vault), uint256(seed) + 1);
        (uint256 capacity, uint256 claims, uint256 liabilities) =
            proof.conservativeCapacity(coordinator);
        assertEq(capacity, 0, "donation created protocol fees");
        assertEq(claims, 130000, "donation changed user claims");
        assertEq(liabilities, 130000, "donation changed protected liabilities");
    }

    function test_UnsettledCrossMarketRiskRejectsAnyFeeSurplus() public {
        PortfolioFeeSolvencyPreflight proof = new PortfolioFeeSolvencyPreflight();
        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        coordinator.take(0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        token.mint(address(vault), 1000000);

        (bool accepted,) = address(proof).call(
            abi.encodeCall(proof.conservativeCapacity, (coordinator))
        );
        assertTrue(!accepted, "unsettled maker/taker positions were ignored");
    }
    function test_BothMarketsFullySettledConserveFeeAndCollateralBacking() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(MAKER);
        coordinator.addLiquidity(1, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        coordinator.take(0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(TAKER);
        coordinator.take(1, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core0.settle(IOrderBookCore.Side.Ask, 100);
        vm.prank(MAKER);
        core1.settle(IOrderBookCore.Side.Ask, 100);

        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Bid, 100, 100);
        vm.prank(MAKER);
        coordinator.addLiquidity(1, IOrderBookCore.Side.Bid, 100, 100);
        vm.prank(TAKER);
        coordinator.take(0, IOrderBookCore.Side.Ask, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(TAKER);
        coordinator.take(1, IOrderBookCore.Side.Ask, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core0.settle(IOrderBookCore.Side.Bid, 100);
        vm.prank(MAKER);
        core1.settle(IOrderBookCore.Side.Bid, 100);
        coordinator.syncAccount(MAKER);
        coordinator.syncAccount(TAKER);

        (int80 m0,,) = core0.accountRisk(MAKER);
        (int80 m1,,) = core1.accountRisk(MAKER);
        assertEq(int256(m0), 0, "first market position not flat");
        assertEq(int256(m1), 0, "second market position not flat");
        assertEq(core0.activeQuoteCount(MAKER), 0, "first market maker quote persists");
        assertEq(core1.activeQuoteCount(MAKER), 0, "second market maker quote persists");

        PortfolioFeeSolvencyPreflight proof = new PortfolioFeeSolvencyPreflight();
        (uint256 capacity, uint256 claims, uint256 liabilities) =
            proof.conservativeCapacity(coordinator);
        assertEq(core0.protocolFeesAccrued() + core1.protocolFeesAccrued(), 500,
            "combined fees not conserved");
        assertEq(claims, 129500, "positive cross-market claims do not reconcile");
        assertEq(liabilities, 129500, "incorrect portfolio liability floor");
        assertEq(capacity, 500, "fully settled portfolio fees not backed");
        assertEq(token.balanceOf(address(vault)), claims + capacity,
            "physical vault collateral diverged from net user claims and fees");
    }

    function test_ReservedLazyMakerRebateCannotBeCalledProtocolFees() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        coordinator.take(0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);

        assertEq(core0.protocolFeesAccrued(), 50, "expected protocol fee mismatch");
        assertEq(core0.pendingMakerRebateReserve(), 50, "unattributed maker rebate not protected");
        assertEq(core1.pendingMakerRebateReserve(), 0, "other market invented rebate");

        vm.prank(MAKER);
        core0.settle(IOrderBookCore.Side.Ask, 100);
        assertEq(core0.pendingMakerRebateReserve(), 0, "settled maker rebate remains escrowed");
        assertEq(core0.protocolFeesAccrued(), 50, "maker settlement reclaimed protocol fee");
    }

}

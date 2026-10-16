// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioTwoMarketFeeIsolationTest} from "./PortfolioTwoMarketFeeIsolation.t.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

/// @notice Real shared-vault distributions consume earned fees from their
/// originating markets, preserving positive claims across both markets.
contract Issue203PortfolioTreasuryPayoutTest is PortfolioTwoMarketFeeIsolationTest {
    address internal constant TREASURY = address(0xFEED);

    function _closedPortfolioRoundTrip() internal {
        for (uint256 i; i < 2; ++i) {
            vm.prank(MAKER);
            coordinator.addLiquidity(i, IOrderBookCore.Side.Ask, 100, 100);
            vm.prank(TAKER);
            coordinator.take(i, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
            vm.prank(MAKER);
            (i == 0 ? core0 : core1).settle(IOrderBookCore.Side.Ask, 100);

            vm.prank(MAKER);
            coordinator.addLiquidity(i, IOrderBookCore.Side.Bid, 100, 100);
            vm.prank(TAKER);
            coordinator.take(i, IOrderBookCore.Side.Ask, 100, 100, IOrderBookCore.FillPolicy.IOC);
            vm.prank(MAKER);
            (i == 0 ? core0 : core1).settle(IOrderBookCore.Side.Bid, 100);
        }
        coordinator.syncAccount(MAKER);
        coordinator.syncAccount(TAKER);
    }

    function _amounts(uint256 fee0, uint256 fee1)
        internal pure returns (uint256[] memory result)
    {
        result = new uint256[](2);
        result[0] = fee0;
        result[1] = fee1;
    }

    function test_PartialAndFullPortfolioPayoutDebitsBothMarketFeeLedgers() public {
        coordinator.configureTreasuryRecipient(TREASURY);
        _closedPortfolioRoundTrip();
        assertEq(core0.protocolFeesAccrued(), 100, "first earned market fees wrong");
        assertEq(core1.protocolFeesAccrued(), 400, "second earned market fees wrong");

        coordinator.withdrawPortfolioProtocolFees(_amounts(40, 160));
        assertEq(token.balanceOf(TREASURY), 200, "partial treasury payout not exact");
        assertEq(core0.protocolFeesAccrued(), 60, "first market fee debit incorrect");
        assertEq(core1.protocolFeesAccrued(), 240, "second market fee debit incorrect");
        assertEq(vault.totalAccountedCollateral(), 129800,
            "shared vault accounting not adjusted for paid fees");

        coordinator.withdrawPortfolioProtocolFees(_amounts(60, 240));
        assertEq(token.balanceOf(TREASURY), 500, "full treasury payout not exact");
        assertEq(core0.protocolFeesAccrued(), 0, "first fee ledger not exhausted");
        assertEq(core1.protocolFeesAccrued(), 0, "second fee ledger not exhausted");
        assertEq(token.balanceOf(address(vault)), 129500, "protected vault backing spent");
        assertEq(vault.totalAccountedCollateral(), 129500, "accounted custody mismatch");

        (bool replay,) = address(coordinator).call(
            abi.encodeCall(coordinator.withdrawPortfolioProtocolFees, (_amounts(1, 0)))
        );
        assertTrue(!replay, "replayed payout minted protocol fees");
    }

    function test_UnprovedMarketAmountsAreAtomicAndCannotRaidOtherMarket() public {
        coordinator.configureTreasuryRecipient(TREASURY);
        _closedPortfolioRoundTrip();

        uint256 vaultBefore = token.balanceOf(address(vault));
        (bool paid,) = address(coordinator).call(
            abi.encodeCall(coordinator.withdrawPortfolioProtocolFees, (_amounts(101, 0)))
        );
        assertTrue(!paid, "first market overspent its own fee ledger");
        assertEq(core0.protocolFeesAccrued(), 100, "failed payout changed first market");
        assertEq(core1.protocolFeesAccrued(), 400, "failed payout changed second market");
        assertEq(token.balanceOf(address(vault)), vaultBefore, "failed payout moved backing");
        assertEq(vault.totalAccountedCollateral(), vaultBefore, "failed payout damaged accounting");
    }

    function test_OnlyPolicyOwnerMayBindImmutableTreasuryAndTransferFees() public {
        vm.prank(MAKER);
        (bool bound,) = address(coordinator).call(
            abi.encodeCall(coordinator.configureTreasuryRecipient, (TREASURY))
        );
        assertTrue(!bound, "untrusted trader configured portfolio treasury");

        coordinator.configureTreasuryRecipient(TREASURY);
        (bool rebound,) = address(coordinator).call(
            abi.encodeCall(coordinator.configureTreasuryRecipient, (MAKER))
        );
        assertTrue(!rebound, "portfolio treasury recipient can be redirected");

        _closedPortfolioRoundTrip();
        vm.prank(MAKER);
        (bool paid,) = address(coordinator).call(
            abi.encodeCall(coordinator.withdrawPortfolioProtocolFees, (_amounts(50, 0)))
        );
        assertTrue(!paid, "untrusted trader paid portfolio treasury");
        assertEq(token.balanceOf(TREASURY), 0, "unauthorized token transfer");
    }

    function test_AnyUnsettledMarketFailsClosedDespiteEarnedFeesAndDonations() public {
        coordinator.configureTreasuryRecipient(TREASURY);
        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        coordinator.take(0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        token.mint(address(vault), 100000);
        uint256 vaultBefore = token.balanceOf(address(vault));

        (bool paid,) = address(coordinator).call(
            abi.encodeCall(coordinator.withdrawPortfolioProtocolFees, (_amounts(1, 0)))
        );
        assertTrue(!paid, "unsettled market permitted portfolio fee distribution");
        assertEq(token.balanceOf(address(vault)), vaultBefore, "failed payout moved custody");
        assertEq(core0.protocolFeesAccrued(), 50, "failed payout reduced protocol fee reserve");
    }

    function test_InsuranceAllocationCannotBePaidAsPortfolioFee() public {
        coordinator.configureTreasuryRecipient(TREASURY);
        _closedPortfolioRoundTrip();
        core1.allocateProtocolFeesToInsurance(100);

        coordinator.withdrawPortfolioProtocolFees(_amounts(100, 300));
        assertEq(token.balanceOf(TREASURY), 400, "fee payout did not respect insurance");
        assertEq(core1.insuranceReserves(), 100, "insurance paid out as fees");
        assertEq(token.balanceOf(address(vault)), 129600, "insurance backing consumed");
        assertEq(vault.totalAccountedCollateral(), 129600, "custody accounting drifted");
    }
}

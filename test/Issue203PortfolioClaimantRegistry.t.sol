// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioTwoMarketFeeIsolationTest} from "./PortfolioTwoMarketFeeIsolation.t.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

contract Issue203PortfolioClaimantRegistryTest is PortfolioTwoMarketFeeIsolationTest {
    function test_CustodyRosterIncludesDepositorsWithoutTradingActivity() public {
        assertEq(vault.custodyClaimantCount(), 2, "initial collateral depositors missing");
        assertTrue(vault.custodyClaimantAt(0) == MAKER, "first depositor missing");
        assertTrue(vault.custodyClaimantAt(1) == TAKER, "second depositor missing");
        assertEq(core0.claimantCount(), 0, "market roster invented activity");
        assertEq(core1.claimantCount(), 0, "other market roster invented activity");
    }

    function test_MarketActivityDoesNotLoseIndependentVaultClaimants() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        coordinator.take(0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);

        assertEq(core0.claimantCount(), 2, "market trading claimants missing");
        assertEq(core1.claimantCount(), 0, "inactive market acquired claims");
        assertEq(vault.custodyClaimantCount(), 2, "vault depositors duplicated");
        assertTrue(vault.custodyClaimantAt(0) == MAKER, "maker depositor reordered");
        assertTrue(vault.custodyClaimantAt(1) == TAKER, "taker depositor reordered");
    }

    function testFuzz_DonationsDoNotManufactureClaimants(uint96 seed) public {
        token.mint(address(vault), uint256(seed) + 1);
        assertEq(vault.custodyClaimantCount(), 2, "token donation added a false claimant");
    }
}

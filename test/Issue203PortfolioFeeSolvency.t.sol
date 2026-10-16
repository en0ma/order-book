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
}

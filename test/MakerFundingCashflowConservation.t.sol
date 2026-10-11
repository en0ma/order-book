// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @notice Reconciles real maker/taker ledgers after lazy funding settlement.
contract MakerFundingCashflowConservationTest is TestBase {
    function testSettlementMakerAFirst() public {
        _checkConservation(false);
    }

    function testSettlementMakerBFirst() public {
        _checkConservation(true);
    }

    function _checkConservation(bool reverse) internal {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        OrderBookCoreHarness core =
            new OrderBookCoreHarness(address(token), address(oracle), 30, 1_000, 0, 0);

        address makerA = address(0xA11CE);
        address makerB = address(0xB0B);
        address taker = address(0xCAFE);
        address[3] memory accounts = [makerA, makerB, taker];
        for (uint256 i; i < accounts.length; ++i) {
            token.mint(accounts[i], 100_000);
            vm.prank(accounts[i]);
            token.approve(address(core), type(uint256).max);
            vm.prank(accounts[i]);
            core.depositCollateral(100_000);
        }

        vm.prank(makerA);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);
        vm.prank(makerB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);

        vm.prank(taker);
        uint96 filled = core.take(
            IOrderBookCore.Side.Bid, 100, 20, IOrderBookCore.FillPolicy.IOC
        );
        assertEq(uint256(filled), 20, "incorrect taker fill");

        // Makers are still lazily unsettled when the funding index advances.
        core.setFundingIndex(1e18);
        address first = reverse ? makerB : makerA;
        address second = reverse ? makerA : makerB;
        vm.prank(first);
        core.settle(IOrderBookCore.Side.Ask, 100);
        vm.prank(second);
        core.settle(IOrderBookCore.Side.Ask, 100);

        int256 netPosition;
        int256 netTrade;
        int256 netFunding;
        for (uint256 i; i < accounts.length; ++i) {
            (int80 position,,) = core.accountRisk(accounts[i]);
            (, int256 trading, int256 funding,, int128 checkpoint) =
                core.accountingStateTest(accounts[i]);
            netPosition += int256(position);
            netTrade += trading;
            // The taker's funding is pending until a state transition settles it.
            int256 pendingFunding =
                -(int256(position) * (int256(core.fundingIndexTest()) - int256(checkpoint))) / 1e18;
            netFunding += funding + pendingFunding;
        }

        assertEq(netPosition, 0, "maker/taker positions not conserved");
        assertEq(netTrade, 0, "fee-free trade cashflows not conserved");
        assertEq(netFunding, 0, "maker/taker funding not conserved");
        assertEq(
            token.balanceOf(address(core)), 300_000,
            "ledger settlement moved collateral unexpectedly"
        );
    }
}

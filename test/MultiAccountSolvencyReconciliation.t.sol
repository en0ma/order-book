// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @notice Reconciles four independently funded accounts across two pro-rata maker pools,
/// two taker directions, funding checkpoints, lazy settlement and actual withdrawals.
/// @dev Fee-free to assert exact zero-sum obligations, separately from fee/rebate tests.
contract MultiAccountSolvencyReconciliationTest is TestBase {
    event SolvencyDiagnostic(int256 netFunding, int256 makerDust);
    address constant A = address(0xA11CE);
    address constant B = address(0xB0B);
    address constant C = address(0xCAFE);
    address constant D = address(0xDA7E);

    function testSettlementAFirst() public { _reconcile(false); }
    function testSettlementBFirst() public { _reconcile(true); }

    function _reconcile(bool reverse) internal {
        MockERC20 token = new MockERC20();
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(new MockMarkOracle(100)), 30, 1000, 0, 0
        );
        address[4] memory accounts = [A, B, C, D];
        for (uint256 i; i < 4; ++i) {
            token.mint(accounts[i], 100_000);
            vm.prank(accounts[i]); token.approve(address(core), type(uint256).max);
            vm.prank(accounts[i]); core.depositCollateral(100_000);
        }
        _assertCustody(token, core, 400_000);
        vm.prank(A); core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);
        vm.prank(B); core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);
        vm.prank(C);
        assertEq(core.take(IOrderBookCore.Side.Bid, 100, 20, IOrderBookCore.FillPolicy.IOC), 20, "open fill");
        _assertCustody(token, core, 400_000);

        core.setFundingIndex(1e18);
        vm.prank(D); core.addLiquidity(IOrderBookCore.Side.Bid, 100, 20);
        vm.prank(C);
        assertEq(core.take(IOrderBookCore.Side.Ask, 100, 20, IOrderBookCore.FillPolicy.IOC), 20, "close fill");
        _assertCustody(token, core, 400_000);

        vm.prank(reverse ? B : A); core.settle(IOrderBookCore.Side.Ask, 100);
        vm.prank(reverse ? A : B); core.settle(IOrderBookCore.Side.Ask, 100);
        vm.prank(D); core.settle(IOrderBookCore.Side.Bid, 100);

        int256 positions;
        int256 trading;
        int256 funding;
        int256 netSettledCash;
        for (uint256 i; i < 4; ++i) {
            (int80 position,,) = core.accountRisk(accounts[i]);
            (uint256 collateral, int256 trade, int256 accrued,, int128 checkpoint) =
                core.accountingStateTest(accounts[i]);
            int256 pending = -(int256(position) *
                (int256(core.fundingIndexTest()) - int256(checkpoint))) / 1e18;
            positions += int256(position);
            trading += trade;
            funding += accrued + pending;
            netSettledCash += int256(collateral) + trade + accrued + pending;
        }
        assertEq(positions, 0, "net position created");
        assertEq(trading, 0, "trade cashflow created");
        int256 makerDust = core.makerFundingRoundingDustTest();
        emit SolvencyDiagnostic(funding, makerDust);
        assertEq(funding + makerDust, 0, "funding including system dust not conserved");
        assertEq(netSettledCash + makerDust, 400_000, "global cash claims and dust not conserved");
        (int80 closedPosition,,) = core.accountRisk(C);
        assertEq(int256(closedPosition), 0, "taker position not flat");
        assertEq(core.accountEquity(C), 100_000 - 20, "funding charge not reflected");

        vm.prank(C); core.withdrawCollateral(99_980);
        _assertCustody(token, core, 300_020);
        (uint256 collateralAfter, int256 tradeAfter, int256 fundingAfter,,) =
            core.accountingStateTest(C);
        assertEq(int256(collateralAfter) + tradeAfter + fundingAfter, 0, "withdrawal left cash claim");
        assertEq(core.accountEquity(C), 0, "flat withdrawal left equity");
        // Other accounts' positive and negative claims still offset to remaining custody.
        int256 otherClaims;
        address[3] memory others = [A, B, D];
        for (uint256 i; i < 3; ++i) {
            (int80 pos,,) = core.accountRisk(others[i]);
            (uint256 collateral, int256 trade, int256 accrued,, int128 checkpoint) =
                core.accountingStateTest(others[i]);
            int256 pending = -(int256(pos) *
                (int256(core.fundingIndexTest()) - int256(checkpoint))) / 1e18;
            otherClaims += int256(collateral) + trade + accrued + pending;
        }
        assertEq(otherClaims + makerDust, 300_020, "post-withdraw solvency reconciliation failed");
    }
    function _assertCustody(MockERC20 token, OrderBookCoreHarness core, uint256 expected) internal view {
        assertEq(token.balanceOf(address(core)), expected, "custody drift");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {PortfolioAdmissionCoordinator} from "../src/deployable/PortfolioAdmissionCoordinator.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {Issue203HostileTreasuryToken} from "./Issue203HostileTreasuryToken.t.sol";

contract Issue203HostilePortfolioFeePayoutTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);
    address internal constant TREASURY = address(0xFEED);
    Issue203HostileTreasuryToken internal token;
    OrderBookCore internal core0;
    OrderBookCore internal core1;
    PortfolioCollateralVault internal vault;
    PortfolioAdmissionCoordinator internal coordinator;

    function setUp() public {
        token = new Issue203HostileTreasuryToken();
        MockMarkOracle mark0 = new MockMarkOracle(100);
        MockMarkOracle mark1 = new MockMarkOracle(100);
        core0 = new OrderBookCore(address(token), address(mark0), 30, 1000, 100, 50);
        core1 = new OrderBookCore(address(token), address(mark1), 30, 1000, 200, 0);
        AdvancedOrderModule g0 = new AdvancedOrderModule(address(core0), address(mark0));
        AdvancedOrderModule g1 = new AdvancedOrderModule(address(core1), address(mark1));
        core0.configureAdvancedModule(address(g0));
        core1.configureAdvancedModule(address(g1));

        PortfolioMarginPolicy.MarketInput[] memory risk =
            new PortfolioMarginPolicy.MarketInput[](2);
        risk[0] = PortfolioMarginPolicy.MarketInput(address(core0), 1, 1000, 0);
        risk[1] = PortfolioMarginPolicy.MarketInput(address(core1), 2, 1000, 0);
        PortfolioMarginPolicy policy = new PortfolioMarginPolicy(risk);
        vault = new PortfolioCollateralVault(address(token));

        PortfolioAdmissionCoordinator.MarketInput[] memory markets =
            new PortfolioAdmissionCoordinator.MarketInput[](2);
        markets[0] = PortfolioAdmissionCoordinator.MarketInput(address(core0), address(g0));
        markets[1] = PortfolioAdmissionCoordinator.MarketInput(address(core1), address(g1));
        coordinator = new PortfolioAdmissionCoordinator(address(policy), address(vault), markets);
        vault.configureController(address(coordinator));
        policy.configureSharedCollateralVault(address(vault));
        core0.configurePortfolioController(address(coordinator));
        core1.configurePortfolioController(address(coordinator));

        token.mint(MAKER, 100000);
        token.mint(TAKER, 30000);
        vm.prank(MAKER);
        token.approve(address(vault), 100000);
        vm.prank(MAKER);
        vault.deposit(100000);
        vm.prank(TAKER);
        token.approve(address(vault), 30000);
        vm.prank(TAKER);
        vault.deposit(30000);
        coordinator.configureTreasuryRecipient(TREASURY);
        coordinator.setFeeDistributionEnabled(true);
    }

    function _closeRoundTrips() internal {
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

    function _pay(uint256 first, uint256 second) internal returns (bool) {
        uint256[] memory marketAmounts = new uint256[](2);
        marketAmounts[0] = first;
        marketAmounts[1] = second;
        (bool ok,) = address(coordinator).call(
            abi.encodeCall(coordinator.withdrawPortfolioProtocolFees, (marketAmounts))
        );
        return ok;
    }

    function testFuzz_TaxedERC20ExtraDebitRollsBackAllMarketFeeLedgers(uint8 extraSeed) public {
        _closeRoundTrips();
        token.configure(uint256(extraSeed) + 1, 0, false);
        assertTrue(!_pay(20, 30), "extra-debit token funded fee payout");
        assertEq(token.balanceOf(address(vault)), 130000, "failed payout spent vault");
        assertEq(core0.protocolFeesAccrued(), 100, "first market fees changed");
        assertEq(core1.protocolFeesAccrued(), 400, "second market fees changed");
        assertEq(vault.totalAccountedCollateral(), 130000, "failed payout changed custody ledger");
        assertEq(token.balanceOf(TREASURY), 0, "failed payout credited treasury");
    }

    function testFuzz_RecipientUndercreditRollsBackAllMarketFeeLedgers(uint8 shortfallSeed) public {
        _closeRoundTrips();
        token.configure(0, uint256(shortfallSeed) % 50 + 1, false);
        assertTrue(!_pay(20, 30), "undercredit token funded fee payout");
        assertEq(core0.protocolFeesAccrued(), 100, "failed transfer debited first fee ledger");
        assertEq(core1.protocolFeesAccrued(), 400, "failed transfer debited second fee ledger");
        assertEq(token.balanceOf(address(vault)), 130000, "failed transfer damaged vault backing");
        assertEq(vault.totalAccountedCollateral(), 130000, "failed transfer damaged ledger");
    }

    function test_TokenCallbackCannotRecursivelyReenterManagedCustody() public {
        _closeRoundTrips();
        token.configure(0, 0, true);
        token.setCallbackData(abi.encodeCall(vault.deposit, (uint256(1))));

        assertTrue(_pay(20, 30), "ordinary backed fee transfer failed");
        assertTrue(token.callbackRejected(), "recursive token callback entered vault");
        assertEq(core0.protocolFeesAccrued(), 80, "first market fee debit mismatch");
        assertEq(core1.protocolFeesAccrued(), 370, "second market fee debit mismatch");
        assertEq(token.balanceOf(TREASURY), 50, "treasury credited wrong fee amount");
        assertEq(vault.totalAccountedCollateral(), 129950, "portfolio claims changed incorrectly");
        assertEq(token.balanceOf(address(vault)), 129950, "fee transfer did not conserve vault custody");
    }
}

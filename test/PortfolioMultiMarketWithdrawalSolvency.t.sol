// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {PortfolioAdmissionCoordinator} from "../src/deployable/PortfolioAdmissionCoordinator.sol";
import {PortfolioLiquidationModule} from "../src/deployable/PortfolioLiquidationModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @notice Two-market withdrawals respect conservative cash equity excluding marked open-position value.
/// @dev Uses real order-book fills and a single custody vault; prices are controlled fixtures.
contract PortfolioMultiMarketWithdrawalSolvencyTest is TestBase {
    address internal constant TRADER = address(0xA11CE);
    address internal constant MAKER = address(0xB0B);
    address internal constant EXIT_MAKER = address(0xD00D);

    MockERC20 internal token;
    MockMarkOracle internal firstMark;
    MockMarkOracle internal secondMark;
    OrderBookCore internal first;
    OrderBookCore internal second;
    PortfolioCollateralVault internal vault;
    PortfolioMarginPolicy internal policy;
    PortfolioAdmissionCoordinator internal coordinator;

    function setUp() public {
        token = new MockERC20();
        firstMark = new MockMarkOracle(100);
        secondMark = new MockMarkOracle(100);
        first = new OrderBookCore(address(token), address(firstMark), 30, 1000, 0, 0);
        second = new OrderBookCore(address(token), address(secondMark), 30, 1000, 0, 0);
        AdvancedOrderModule g0 = new AdvancedOrderModule(address(first), address(firstMark));
        AdvancedOrderModule g1 = new AdvancedOrderModule(address(second), address(secondMark));
        first.configureAdvancedModule(address(g0));
        second.configureAdvancedModule(address(g1));

        PortfolioMarginPolicy.MarketInput[] memory policies =
            new PortfolioMarginPolicy.MarketInput[](2);
        policies[0] = PortfolioMarginPolicy.MarketInput(address(first), 1, 1000, 0);
        policies[1] = PortfolioMarginPolicy.MarketInput(address(second), 2, 1000, 0);
        policy = new PortfolioMarginPolicy(policies);
        vault = new PortfolioCollateralVault(address(token));
        PortfolioAdmissionCoordinator.MarketInput[] memory markets =
            new PortfolioAdmissionCoordinator.MarketInput[](2);
        markets[0] = PortfolioAdmissionCoordinator.MarketInput(address(first), address(g0));
        markets[1] = PortfolioAdmissionCoordinator.MarketInput(address(second), address(g1));
        coordinator = new PortfolioAdmissionCoordinator(address(policy), address(vault), markets);
        vault.configureController(address(coordinator));
        policy.configureSharedCollateralVault(address(vault));
        first.configurePortfolioController(address(coordinator));
        second.configurePortfolioController(address(coordinator));

        _deposit(TRADER, 13000);
        _deposit(MAKER, 100000);
        _deposit(EXIT_MAKER, 100000);

        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(MAKER);
        coordinator.addLiquidity(1, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TRADER);
        assertEq(uint256(coordinator.take(
            0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC
        )), 100, "first opening fill");
        vm.prank(TRADER);
        assertEq(uint256(coordinator.take(
            1, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC
        )), 100, "second opening fill");
    }

    function testMarkedProfitInOneMarketCannotFundWithdrawalAfterOtherMarketRealizesLoss() public {
        firstMark.setMarkTick(120); // +2000 still open/unrealized; open entry cashflow remains -10000.
        secondMark.setMarkTick(90); // Closing will realize -1000.
        vm.prank(EXIT_MAKER);
        coordinator.addLiquidity(1, IOrderBookCore.Side.Bid, 90, 100);
        vm.prank(TRADER);
        assertEq(uint256(coordinator.take(
            1, IOrderBookCore.Side.Ask, 90, 100, IOrderBookCore.FillPolicy.IOC
        )), 100, "second closing fill");

        (int80 firstPosition,,) = first.accountRisk(TRADER);
        (int80 secondPosition,,) = second.accountRisk(TRADER);
        assertEq(int256(firstPosition), 100, "profitable exposure unexpectedly closed");
        assertEq(int256(secondPosition), 0, "losing exposure not flattened");
        assertEq(coordinator.settledCashEquity(TRADER), 2000, "conservative cash-equity basis incorrect");
        assertEq(policy.portfolioEquity(TRADER), 14000, "unrealized profit not in marked equity");

        uint256 beforeBalance = token.balanceOf(TRADER);
        uint256 beforeCustody = token.balanceOf(address(vault));
        uint256 beforeAccounted = vault.totalAccountedCollateral();
        vm.prank(TRADER);
        (bool ok,) = address(coordinator).call(
            abi.encodeCall(coordinator.withdraw, (uint256(2001)))
        );
        assertTrue(!ok, "withdrawal consumed unrealized gain");
        assertEq(token.balanceOf(TRADER), beforeBalance, "reverted withdrawal paid tokens");
        assertEq(token.balanceOf(address(vault)), beforeCustody, "reverted withdrawal spent custody");
        assertEq(vault.totalAccountedCollateral(), beforeAccounted, "reverted withdrawal changed claims");

        // Settled cash is not itself fully withdrawable: the first open market
        // continues to consume portfolio initial-margin capacity.
        vm.prank(TRADER);
        coordinator.withdraw(1000);
        assertEq(token.balanceOf(TRADER), beforeBalance + 1000, "legitimate cash withdrawal missing");
        assertEq(coordinator.settledCashEquity(TRADER), 1000, "cash basis not reduced");
        assertEq(vault.totalAccountedCollateral(), beforeAccounted - 1000, "vault claim mismatch");
        assertEq(token.balanceOf(address(vault)), beforeCustody - 1000, "vault custody mismatch");
    }

    function testFuzz_CrossMarketFundingPublicationDoesNotLeakCustody(
        uint32 indexSeed,
        uint16 withdrawalSeed
    ) public {
        // Both markets have open long positions, but all custody stays in
        // the same vault. Funding publication changes market equity without
        // adding collateral or realizing an independent token source.
        int128 fundingIndex = int128(int256(uint256(indexSeed) % 2e17));
        first.setFundingIndex(fundingIndex);
        second.setFundingIndex(-fundingIndex);

        uint256 initialCustody = token.balanceOf(address(vault));
        uint256 initialAccounted = vault.totalAccountedCollateral();
        assertEq(initialCustody, initialAccounted, "pre-withdraw vault backing");

        uint256 requested = uint256(withdrawalSeed % 20_000) + 1;
        vm.prank(TRADER);
        (bool ok,) = address(coordinator).call(
            abi.encodeCall(coordinator.withdraw, (requested))
        );

        uint256 finalCustody = token.balanceOf(address(vault));
        uint256 finalAccounted = vault.totalAccountedCollateral();
        assertEq(finalCustody, finalAccounted, "cross-market custody backing");
        assertTrue(finalCustody <= initialCustody, "withdrawal inflated custody");
        if (ok) {
            assertEq(initialCustody - finalCustody, requested,
                "success did not debit physical custody");
            assertEq(initialAccounted - finalAccounted, requested,
                "success did not debit accounted collateral");
            int256 claim = vault.collateralClaim(TRADER);
            uint256 locked = vault.lockedCollateral(TRADER);
            if (claim > 0) {
                assertTrue(uint256(claim) >= locked,
                    "successful withdrawal broke trader collateral lock");
            } else {
                assertEq(locked, 0, "negative claim retained positive lock");
            }
        } else {
            assertEq(finalCustody, initialCustody, "failed withdrawal moved tokens");
            assertEq(finalAccounted, initialAccounted,
                "failed withdrawal changed backing ledger");
        }
        assertEq(token.balanceOf(address(first)), 0, "first market took shared custody");
        assertEq(token.balanceOf(address(second)), 0, "second market took shared custody");
    }

    function testRealTwoMarketTerminalLiquidationPreservesVaultAndResidualDebt() public {
        // Liquidation uses actual OrderBookCore positions and two AdvancedOrderModule
        // gateways; neither Core is permitted to receive shared vault tokens.
        PortfolioLiquidationModule.MarketInput[] memory configs =
            new PortfolioLiquidationModule.MarketInput[](2);
        (IOrderBookCore firstCore, address firstGateway) = coordinator.markets(0);
        (IOrderBookCore secondCore, address secondGateway) = coordinator.markets(1);
        configs[0] = PortfolioLiquidationModule.MarketInput(address(firstCore), firstGateway);
        configs[1] = PortfolioLiquidationModule.MarketInput(address(secondCore), secondGateway);
        PortfolioLiquidationModule liquidation = new PortfolioLiquidationModule(address(policy), configs);
        AdvancedOrderModule(firstGateway).configureLiquidationModule(address(liquidation));
        AdvancedOrderModule(secondGateway).configureLiquidationModule(address(liquidation));

        firstMark.setMarkTick(1);
        secondMark.setMarkTick(1);
        vm.prank(EXIT_MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Bid, 1, 100);
        vm.prank(EXIT_MAKER);
        coordinator.addLiquidity(1, IOrderBookCore.Side.Bid, 1, 100);

        assertTrue(policy.portfolioEquity(TRADER) < 0, "fixture has no terminal loss");
        assertTrue(liquidation.isLiquidatable(TRADER), "distressed trader not liquidatable");
        uint256 custodyBefore = token.balanceOf(address(vault));
        uint256 accountedBefore = vault.totalAccountedCollateral();

        PortfolioLiquidationModule.CleanupInput[] memory cleanups =
            new PortfolioLiquidationModule.CleanupInput[](2);
        for (uint256 i; i < 2; ++i) {
            cleanups[i].makerSides = new IOrderBookCore.Side[](0);
            cleanups[i].makerTicks = new uint16[](0);
            cleanups[i].conditionalIds = new uint64[](0);
            cleanups[i].trailingIds = new uint64[](0);
            cleanups[i].strategyIds = new uint64[](0);
        }
        assertEq(uint256(liquidation.liquidate(TRADER, cleanups)), 200,
            "cross-market liquidation did not close both positions");
        (int80 posA,,) = first.accountRisk(TRADER);
        (int80 posB,,) = second.accountRisk(TRADER);
        assertEq(int256(posA), 0, "first market left position");
        assertEq(int256(posB), 0, "second market left position");
        assertTrue(policy.portfolioEquity(TRADER) < 0, "terminal debt disappeared");
        assertEq(coordinator.coverBadDebt(TRADER), 0, "unfunded insurance minted coverage");
        assertEq(token.balanceOf(address(vault)), custodyBefore, "liquidation moved shared custody");
        assertEq(vault.totalAccountedCollateral(), accountedBefore,
            "liquidation modified accounted deposits");
        assertEq(token.balanceOf(address(first)), 0, "first Core obtained shared tokens");
        assertEq(token.balanceOf(address(second)), 0, "second Core obtained shared tokens");
    }

    function testFuzz_TerminalCrossMarketDebtCannotDrainSharedVault(
        uint16 markSeed, uint16 withdrawSeed
    ) public {
        // Both genuine Core positions remain open while oracle marks collapse.
        // Neither uncovered bad debt nor apparent portfolio exposure can mint
        // spendable token custody for a distressed account.
        uint16 distressedMark = uint16(uint256(markSeed) % 40 + 1);
        firstMark.setMarkTick(distressedMark);
        secondMark.setMarkTick(distressedMark);
        assertTrue(policy.portfolioEquity(TRADER) < 0, "fixture unexpectedly solvent");

        uint256 custodyBefore = token.balanceOf(address(vault));
        uint256 accountedBefore = vault.totalAccountedCollateral();
        uint256 claimBefore = vault.balanceOf(TRADER);
        int256 equityBefore = policy.portfolioEquity(TRADER);

        (bool covered,) = address(coordinator).call(
            abi.encodeCall(coordinator.coverBadDebt, (TRADER))
        );
        assertTrue(!covered, "insurance covered a still-open market exposure");

        vm.prank(TRADER);
        (bool withdrawn,) = address(coordinator).call(
            abi.encodeCall(coordinator.withdraw, (uint256(withdrawSeed) + 1))
        );
        assertTrue(!withdrawn, "terminal account withdrew against shared collateral");

        assertEq(token.balanceOf(address(vault)), custodyBefore, "terminal risk moved tokens");
        assertEq(vault.totalAccountedCollateral(), accountedBefore, "terminal risk changed backing");
        assertEq(vault.balanceOf(TRADER), claimBefore, "terminal risk changed user claim");
        assertEq(policy.portfolioEquity(TRADER), equityBefore, "failed operations changed equity");
        assertEq(token.balanceOf(address(first)), 0, "first Core received custody");
        assertEq(token.balanceOf(address(second)), 0, "second Core received custody");
    }

    function _deposit(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(vault), amount);
        vm.prank(who);
        vault.deposit(amount);
    }
}

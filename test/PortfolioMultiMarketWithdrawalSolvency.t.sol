// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {PortfolioAdmissionCoordinator} from "../src/deployable/PortfolioAdmissionCoordinator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @notice Two-market PnL cannot turn mark-only profits into withdrawable collateral.
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

        _deposit(TRADER, 3000);
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
        firstMark.setMarkTick(120); // +2000 still open/unrealized.
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
        assertEq(coordinator.settledCashEquity(TRADER), 2000, "cross-market realized cash incorrect");
        assertEq(policy.portfolioEquity(TRADER), 4000, "unrealized profit not in marked equity");

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

    function _deposit(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(vault), amount);
        vm.prank(who);
        vault.deposit(amount);
    }
}

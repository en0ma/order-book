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

/// @notice Two market-specific fee and insurance reserves share one ERC20 vault.
/// @dev No external funding, price identity, or DEX economic policy is assumed.
contract PortfolioTwoMarketFeeIsolationTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);

    MockERC20 internal token;
    MockMarkOracle internal mark0;
    MockMarkOracle internal mark1;
    OrderBookCore internal core0;
    OrderBookCore internal core1;
    AdvancedOrderModule internal gateway0;
    AdvancedOrderModule internal gateway1;
    PortfolioCollateralVault internal vault;
    PortfolioMarginPolicy internal policy;
    PortfolioAdmissionCoordinator internal coordinator;

    function setUp() public {
        token = new MockERC20();
        mark0 = new MockMarkOracle(100);
        mark1 = new MockMarkOracle(100);
        core0 = new OrderBookCore(address(token), address(mark0), 30, 1000, 100, 50);
        core1 = new OrderBookCore(address(token), address(mark1), 30, 1000, 200, 0);
        gateway0 = new AdvancedOrderModule(address(core0), address(mark0));
        gateway1 = new AdvancedOrderModule(address(core1), address(mark1));
        core0.configureAdvancedModule(address(gateway0));
        core1.configureAdvancedModule(address(gateway1));

        PortfolioMarginPolicy.MarketInput[] memory risks =
            new PortfolioMarginPolicy.MarketInput[](2);
        risks[0] = PortfolioMarginPolicy.MarketInput(address(core0), 1, 1000, 0);
        risks[1] = PortfolioMarginPolicy.MarketInput(address(core1), 2, 1000, 0);
        policy = new PortfolioMarginPolicy(risks);
        vault = new PortfolioCollateralVault(address(token));

        PortfolioAdmissionCoordinator.MarketInput[] memory markets =
            new PortfolioAdmissionCoordinator.MarketInput[](2);
        markets[0] = PortfolioAdmissionCoordinator.MarketInput(address(core0), address(gateway0));
        markets[1] = PortfolioAdmissionCoordinator.MarketInput(address(core1), address(gateway1));
        coordinator = new PortfolioAdmissionCoordinator(address(policy), address(vault), markets);
        vault.configureController(address(coordinator));
        policy.configureSharedCollateralVault(address(vault));
        core0.configurePortfolioController(address(coordinator));
        core1.configurePortfolioController(address(coordinator));

        _deposit(MAKER, 100000);
        _deposit(TAKER, 30000);
    }

    function testIndependentMarketFeeRebatesAndInsuranceNeverMoveSharedCustody() public {
        uint256 custodyBefore = token.balanceOf(address(vault));
        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(MAKER);
        coordinator.addLiquidity(1, IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(TAKER);
        assertEq(
            uint256(coordinator.take(0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC)),
            100, "market zero fill"
        );
        vm.prank(TAKER);
        assertEq(
            uint256(coordinator.take(1, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC)),
            100, "market one fill"
        );
        assertEq(core0.protocolFeesAccrued(), 50, "first market rebate not reserved");
        assertEq(core1.protocolFeesAccrued(), 200, "second market fees incorrect");

        core0.allocateProtocolFeesToInsurance(50);
        core1.allocateProtocolFeesToInsurance(75);
        assertEq(core0.insuranceReserves(), 50, "first insurance reserve incorrect");
        assertEq(core1.insuranceReserves(), 75, "second insurance reserve incorrect");
        assertEq(core0.protocolFeesAccrued(), 0, "first reserve not fully allocated");
        assertEq(core1.protocolFeesAccrued(), 125, "second reserve incorrectly allocated");

        vm.prank(MAKER);
        core0.settle(IOrderBookCore.Side.Ask, 100);
        vm.prank(MAKER);
        core1.settle(IOrderBookCore.Side.Ask, 100);
        assertEq(core0.insuranceReserves(), 50, "lazy rebate spent first insurance");
        assertEq(core1.insuranceReserves(), 75, "other market insurance changed");
        assertEq(core0.protocolFeesAccrued(), 0, "rebate settlement recreated fees");
        assertEq(core1.protocolFeesAccrued(), 125, "other market fees changed");
        assertEq(token.balanceOf(address(vault)), custodyBefore, "fee reclassification moved tokens");
        assertEq(vault.totalAccountedCollateral(), custodyBefore, "shared vault accounting mutated");
        assertEq(token.balanceOf(address(core0)), 0, "core zero took vault custody");
        assertEq(token.balanceOf(address(core1)), 0, "core one took vault custody");
    }

    function testOneMarketCannotAllocateAnotherMarketsFeeBalance() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        coordinator.take(0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        uint256 custody = token.balanceOf(address(vault));

        (bool ok,) = address(core1).call(
            abi.encodeCall(core1.allocateProtocolFeesToInsurance, (uint256(1)))
        );
        assertTrue(!ok, "empty market accessed other market fees");
        assertEq(core0.protocolFeesAccrued(), 50, "origin market fees changed");
        assertEq(core1.protocolFeesAccrued(), 0, "second market minted fees");
        assertEq(core0.insuranceReserves(), 0, "origin insurance changed");
        assertEq(core1.insuranceReserves(), 0, "other insurance minted");
        assertEq(token.balanceOf(address(vault)), custody, "unauthorized market allocation moved custody");
    }

    function _deposit(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(vault), amount);
        vm.prank(who);
        vault.deposit(amount);
    }
}

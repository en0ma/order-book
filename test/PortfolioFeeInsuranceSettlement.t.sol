// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {PortfolioAdmissionCoordinator} from "../src/deployable/PortfolioAdmissionCoordinator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {TestBase} from "./TestBase.sol";

contract PortfolioFeeInsuranceSettlementTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);
    address internal constant EXIT_MAKER = address(0xD00D);
    address internal constant LIQUIDATOR = address(0x1A11);

    MockERC20 internal token;
    MockMarkOracle internal oracle;
    OrderBookCore internal core;
    AdvancedOrderModule internal advanced;
    PortfolioMarginPolicy internal policy;
    PortfolioCollateralVault internal vault;
    PortfolioAdmissionCoordinator internal coordinator;

    function setUp() public {
        token = new MockERC20();
        oracle = new MockMarkOracle(100);
        core = new OrderBookCore(
            address(token),
            address(oracle),
            20,
            1_000,
            10,
            0
        );
        advanced = new AdvancedOrderModule(address(core), address(oracle));
        core.configureAdvancedModule(address(advanced));

        PortfolioMarginPolicy.MarketInput[] memory policyInputs =
            new PortfolioMarginPolicy.MarketInput[](1);
        policyInputs[0] = PortfolioMarginPolicy.MarketInput({
            core: address(core),
            riskGroup: 1,
            marginBps: 1_000,
            hedgeCreditBps: 0
        });
        policy = new PortfolioMarginPolicy(policyInputs);

        vault = new PortfolioCollateralVault(address(token));

        PortfolioAdmissionCoordinator.MarketInput[] memory admissionInputs =
            new PortfolioAdmissionCoordinator.MarketInput[](1);
        admissionInputs[0] = PortfolioAdmissionCoordinator.MarketInput({
            core: address(core),
            gateway: address(advanced)
        });
        coordinator = new PortfolioAdmissionCoordinator(
            address(policy),
            address(vault),
            admissionInputs
        );

        vault.configureController(address(coordinator));
        policy.configureSharedCollateralVault(address(vault));
        core.configurePortfolioController(address(coordinator));
        coordinator.configurePortfolioLiquidationModule(address(this));

        _deposit(MAKER, 50_000);
        _deposit(TAKER, 1_010);
        _deposit(EXIT_MAKER, 50_000);
    }

    function testFeeBearingPortfolioTradeAccruesSharedBackedProtocolClaim() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Ask,
            100,
            100
        );

        vm.prank(TAKER);
        uint96 filled = coordinator.take(
            0,
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(filled, 100, "fee-bearing portfolio fill mismatch");
        assertEq(core.protocolFeesAccrued(), 10, "protocol fee mismatch");
        assertEq(
            policy.portfolioEquity(TAKER),
            int256(1_000),
            "taker fee not reflected in portfolio equity"
        );
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "fee accrual changed physical shared custody"
        );
    }

    function testPortfolioLiquidatorRewardConsumesProtocolClaimAndSharedCustody() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Ask,
            100,
            100
        );

        vm.prank(TAKER);
        coordinator.take(
            0,
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(core.protocolFeesAccrued(), 10, "protocol fee precondition");

        uint256 custodyBefore = token.balanceOf(address(vault));
        uint256 liquidatorBefore = token.balanceOf(LIQUIDATOR);

        uint256 paid = coordinator.payLiquidationReward(LIQUIDATOR, 7);

        assertEq(paid, 7, "portfolio reward payment mismatch");
        assertEq(core.protocolFeesAccrued(), 3, "protocol fee claim not burned");
        assertEq(
            token.balanceOf(LIQUIDATOR) - liquidatorBefore,
            7,
            "liquidator did not receive shared custody"
        );
        assertEq(
            custodyBefore - token.balanceOf(address(vault)),
            7,
            "shared custody did not fund reward"
        );
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "system reward broke vault accounting"
        );
    }

    function testProtocolFeesCanFundPortfolioInsuranceAndCoverClosedBadDebt() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Ask,
            100,
            100
        );

        vm.prank(TAKER);
        coordinator.take(
            0,
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        core.allocateProtocolFeesToInsurance(10);
        assertEq(core.protocolFeesAccrued(), 0, "protocol fee not allocated");
        assertEq(core.insuranceReserves(), 10, "insurance reserve mismatch");

        oracle.setMarkTick(1);

        vm.prank(EXIT_MAKER);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Bid,
            1,
            100
        );

        vm.prank(TAKER);
        uint96 closed = advanced.takeReduceOnly(
            IOrderBookCore.Side.Ask,
            1,
            100,
            IOrderBookCore.FillPolicy.IOC
        );
        assertEq(closed, 100, "reduce-only close failed");

        (int80 position,,) = core.accountRisk(TAKER);
        assertEq(int256(position), int256(0), "position not closed");

        int256 equityBefore = policy.portfolioEquity(TAKER);
        assertTrue(equityBefore < 0, "scenario did not create bad debt");

        uint256 covered = coordinator.coverBadDebt(TAKER);

        assertEq(covered, 10, "portfolio insurance coverage mismatch");
        assertEq(core.insuranceReserves(), 0, "insurance reserve not consumed");
        assertEq(
            policy.portfolioEquity(TAKER),
            equityBefore + int256(10),
            "insurance did not become portfolio cash claim"
        );
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "insurance settlement broke shared custody"
        );
    }

    function _deposit(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(vault), type(uint256).max);
        vm.prank(account);
        vault.deposit(amount);
    }
}

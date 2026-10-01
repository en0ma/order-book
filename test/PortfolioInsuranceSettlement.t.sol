// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {PortfolioAdmissionCoordinator} from "../src/deployable/PortfolioAdmissionCoordinator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {TestBase} from "./TestBase.sol";

contract PortfolioInsuranceSettlementTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TRADER = address(0xB0B);
    address internal constant EXIT_MAKER = address(0xD00D);

    MockERC20 internal token;
    MockMarkOracle internal oracle;
    OrderBookCore internal core;
    PortfolioCollateralVault internal vault;
    PortfolioMarginPolicy internal policy;
    PortfolioAdmissionCoordinator internal coordinator;

    function setUp() public {
        token = new MockERC20();
        oracle = new MockMarkOracle(100);

        // 10% taker fee, no maker rebate. The large fee keeps this test
        // numerically compact while exercising the same accounting path.
        core =
            new OrderBookCore(address(token), address(oracle), 20, 1_000, 1_000, 0);
        core.configureAdvancedModule(address(this));

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
            gateway: address(this)
        });
        coordinator = new PortfolioAdmissionCoordinator(
            address(policy),
            address(vault),
            admissionInputs
        );

        vault.configureController(address(coordinator));
        policy.configureSharedCollateralVault(address(vault));
        coordinator.configureSettlementModule(address(this));
        core.configurePortfolioController(address(coordinator));

        _deposit(MAKER, 50_000);
        _deposit(TRADER, 2_000);
        _deposit(EXIT_MAKER, 50_000);
    }

    function testProtocolFeesCanBackPortfolioBadDebt() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Ask,
            100,
            100
        );

        vm.prank(TRADER);
        coordinator.take(
            0,
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(core.protocolFeesAccrued(), 1_000, "initial protocol fee mismatch");

        core.allocateProtocolFeesToInsurance(1_000);
        assertEq(core.protocolFeesAccrued(), 0, "fee allocation did not clear");
        assertEq(core.insuranceReserves(), 1_000, "insurance allocation mismatch");

        oracle.setMarkTick(90);

        vm.prank(EXIT_MAKER);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Bid,
            90,
            100
        );

        // Use the configured advanced-module authority for a reduce-only close.
        // Portfolio-mode non-reduce paths remain coordinator-only.
        uint96 filled = core.moduleTake(
            TRADER,
            IOrderBookCore.Side.Ask,
            90,
            100,
            IOrderBookCore.FillPolicy.IOC,
            true,
            false
        );
        assertEq(filled, 100, "reduce-only close mismatch");

        assertEq(
            policy.portfolioEquity(TRADER),
            int256(-900),
            "expected portfolio bad debt"
        );
        assertEq(
            core.protocolFeesAccrued(),
            900,
            "closing fee did not accrue"
        );

        uint256 covered = core.moduleCoverBadDebt(TRADER, 900);
        assertEq(covered, 900, "insurance coverage mismatch");
        assertEq(core.insuranceReserves(), 100, "insurance reserve mismatch");

        coordinator.creditSystemClaim(TRADER, covered);

        assertEq(
            vault.portfolioCredited(TRADER),
            900,
            "shared insurance credit missing"
        );
        assertEq(
            policy.portfolioEquity(TRADER),
            int256(0),
            "insurance did not clear bad debt"
        );
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "insurance settlement broke shared custody"
        );
    }

    function testPortfolioFeeAccountingStaysInsideSharedCustody() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Ask,
            100,
            25
        );

        vm.prank(TRADER);
        coordinator.take(
            0,
            IOrderBookCore.Side.Bid,
            100,
            25,
            IOrderBookCore.FillPolicy.IOC
        );

        int256 userEquity =
            policy.portfolioEquity(MAKER) + policy.portfolioEquity(TRADER)
                + policy.portfolioEquity(EXIT_MAKER);

        assertTrue(userEquity >= 0, "aggregate user equity negative");
        assertTrue(
            uint256(userEquity) + core.protocolFeesAccrued()
                <= token.balanceOf(address(vault)),
            "user plus protocol claims exceeded custody"
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

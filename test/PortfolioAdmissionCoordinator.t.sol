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

contract PortfolioAdmissionCoordinatorTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);
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
        core = new OrderBookCore(address(token), address(oracle), 20, 1_000, 0, 0);

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
        core.configurePortfolioController(address(coordinator));

        _deposit(MAKER, 20_000);
        _deposit(TAKER, 20_000);
        _deposit(EXIT_MAKER, 20_000);
    }

    function testCoordinatorCanAdmitMakerAndTakerFromSharedCollateral() public {
        vm.prank(MAKER);
        uint128 shares = coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Ask,
            100,
            100
        );
        assertTrue(shares != 0, "maker shares missing");

        vm.prank(TAKER);
        uint96 filled = coordinator.take(
            0,
            IOrderBookCore.Side.Bid,
            100,
            40,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(filled, 40, "portfolio taker fill mismatch");
        (int80 position,,) = core.accountRisk(TAKER);
        assertEq(int256(position), int256(40), "portfolio taker position");

        assertTrue(
            vault.lockedCollateral(TAKER) != 0,
            "portfolio requirement was not locked"
        );
    }

    function testDirectRiskIncreaseIsBlockedInPortfolioMode() public {
        vm.prank(MAKER);
        (bool addOk,) = address(core).call(
            abi.encodeCall(
                core.addLiquidity,
                (IOrderBookCore.Side.Ask, uint16(100), uint96(10))
            )
        );
        assertTrue(!addOk, "direct maker bypassed coordinator");

        vm.prank(TAKER);
        (bool takeOk,) = address(core).call(
            abi.encodeCall(
                core.take,
                (
                    IOrderBookCore.Side.Bid,
                    uint16(100),
                    uint96(10),
                    IOrderBookCore.FillPolicy.IOC
                )
            )
        );
        assertTrue(!takeOk, "direct taker bypassed coordinator");
    }

    function testInsufficientPortfolioCollateralRevertsMarketMutation() public {
        address thin = address(0xCAFE);
        _deposit(thin, 500);

        vm.prank(MAKER);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Ask,
            100,
            100
        );

        vm.prank(thin);
        (bool ok,) = address(coordinator).call(
            abi.encodeCall(
                coordinator.take,
                (
                    uint256(0),
                    IOrderBookCore.Side.Bid,
                    uint16(100),
                    uint96(100),
                    IOrderBookCore.FillPolicy.IOC
                )
            )
        );
        assertTrue(!ok, "undercollateralized portfolio action succeeded");

        (int80 position,,) = core.accountRisk(thin);
        assertEq(int256(position), int256(0), "reverted action changed position");

        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Ask, 100);
        assertEq(uint256(remaining), uint256(100), "reverted action consumed liquidity");
    }

    function testRealizedProfitCanBeWithdrawnFromSharedPool() public {
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

        oracle.setMarkTick(120);

        vm.prank(EXIT_MAKER);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Bid,
            120,
            100
        );

        vm.prank(TAKER);
        coordinator.take(
            0,
            IOrderBookCore.Side.Ask,
            120,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(
            coordinator.settledCashEquity(TAKER),
            int256(22_000),
            "realized cash equity mismatch"
        );

        uint256 beforeTokens = token.balanceOf(TAKER);
        vm.prank(TAKER);
        coordinator.withdraw(21_000);

        uint256 withdrawnTokens = token.balanceOf(TAKER) - beforeTokens;
        assertEq(
            withdrawnTokens,
            uint256(21_000),
            "profit withdrawal amount mismatch"
        );
        int256 collateralClaimAfter = vault.collateralClaim(TAKER);
        int256 settledCashAfter = coordinator.settledCashEquity(TAKER);
        assertEq(
            collateralClaimAfter,
            int256(-1_000),
            "signed collateral claim mismatch"
        );
        assertEq(
            settledCashAfter,
            int256(1_000),
            "post-withdraw cash equity mismatch"
        );
    }

    function testUnrealizedProfitCannotBeWithdrawnAsCash() public {
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

        oracle.setMarkTick(120);

        assertEq(
            policy.portfolioEquity(TAKER),
            int256(22_000),
            "marked equity mismatch"
        );
        assertEq(
            coordinator.settledCashEquity(TAKER),
            int256(10_000),
            "unrealized mark leaked into cash equity"
        );

        vm.prank(TAKER);
        (bool ok,) = address(coordinator).call(
            abi.encodeCall(coordinator.withdraw, (10_001))
        );
        assertTrue(!ok, "unrealized profit was withdrawn");
    }

    function testDirectVaultWithdrawIsBlockedAfterControllerSetup() public {
        vm.prank(TAKER);
        (bool ok,) =
            address(vault).call(abi.encodeCall(vault.withdraw, (1)));
        assertTrue(!ok, "direct vault withdrawal bypassed live risk check");
    }

    function testRealizedLossReducesWithdrawableSharedCollateral() public {
        // Synthetic negative market value with zero position is not directly
        // forgeable on the production core. This property is covered by the
        // lock formula itself: free collateral is equity minus requirement.
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

        uint256 before = vault.freeCollateral(TAKER);
        assertTrue(before < vault.balanceOf(TAKER), "risk did not constrain withdrawal");
    }

    function testPortfolioModeAllowsFeesButRejectsLocalCollateral() public {
        OrderBookCore feeCore =
            new OrderBookCore(address(token), address(oracle), 20, 1_000, 10, 5);
        feeCore.configurePortfolioController(address(coordinator));
        assertEq(
            uint256(uint160(feeCore.portfolioController())),
            uint256(uint160(address(coordinator))),
            "fee-bearing core rejected portfolio mode"
        );

        OrderBookCore fundedCore =
            new OrderBookCore(address(token), address(oracle), 20, 1_000, 0, 0);
        token.mint(address(this), 1_000);
        token.approve(address(fundedCore), type(uint256).max);
        fundedCore.depositCollateral(1_000);

        (bool fundedOk,) = address(fundedCore).call(
            abi.encodeCall(
                fundedCore.configurePortfolioController,
                (address(coordinator))
            )
        );
        assertTrue(!fundedOk, "locally funded core entered portfolio mode");
    }

    function _deposit(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(vault), type(uint256).max);
        vm.prank(account);
        vault.deposit(amount);
    }
}

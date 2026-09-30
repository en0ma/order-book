// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {TestBase} from "./TestBase.sol";

contract DeployableCoreTest is TestBase {
    OrderBookCore internal core;
    MockERC20 internal token;
    MockMarkOracle internal oracle;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        oracle = new MockMarkOracle(100);
        core = new OrderBookCore(address(token), address(oracle), 20, 1_000, 0, 0);
        core.configureAdvancedModule(address(this));

        _fund(ALICE, 100_000);
        _fund(BOB, 100_000);
        _fund(address(this), 100_000);
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }

    function testDirectHotPathStillMatchesOnChain() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        uint96 filled =
            core.take(IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC);

        assertEq(filled, 40, "core direct fill mismatch");
        assertEq(int256(_corePosition(address(this))), 40, "taker position mismatch");
    }

    function testDirectAskTakerShiftsEntireRiskEnvelope() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 20);

        vm.prank(BOB);
        uint96 filled =
            core.take(IOrderBookCore.Side.Ask, 100, 13, IOrderBookCore.FillPolicy.IOC);

        assertEq(filled, 13, "ask fill mismatch");

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(BOB);

        assertEq(int256(settled), -13, "ask settled position");
        assertEq(int256(minPosition), -13, "ask min envelope");
        assertEq(int256(maxPosition), -13, "ask max envelope");
    }

    function testFeesChargeTakerImmediatelyAndRebateMakerLazily() public {
        MockERC20 feeToken = new MockERC20();
        MockMarkOracle feeOracle = new MockMarkOracle(100);
        OrderBookCore feeCore =
            new OrderBookCore(address(feeToken), address(feeOracle), 20, 1_000, 10, 5);

        _fundOn(feeCore, feeToken, ALICE, 100_000);
        _fundOn(feeCore, feeToken, BOB, 100_000);

        vm.prank(ALICE);
        feeCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(BOB);
        uint96 filled =
            feeCore.take(IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC);
        assertEq(filled, 40, "fee fill mismatch");

        assertEq(feeCore.accountEquity(BOB), 99_996, "taker fee not charged immediately");
        assertEq(feeCore.accountEquity(ALICE), 100_000, "maker rebate materialized before settlement");
        assertEq(feeCore.protocolFeesAccrued(), 2, "protocol net fee after taker fill");

        vm.prank(ALICE);
        feeCore.settle(IOrderBookCore.Side.Ask, 100);

        assertEq(feeCore.accountEquity(ALICE), 100_002, "maker rebate not applied on settlement");
        assertEq(feeCore.protocolFeesAccrued(), 2, "maker settlement double-counted protocol fee");
    }

    function testFeesAcrossPartialMakerSettlementsAccrueExactlyOnce() public {
        MockERC20 feeToken = new MockERC20();
        MockMarkOracle feeOracle = new MockMarkOracle(100);
        OrderBookCore feeCore =
            new OrderBookCore(address(feeToken), address(feeOracle), 20, 1_000, 10, 5);

        _fundOn(feeCore, feeToken, ALICE, 100_000);
        _fundOn(feeCore, feeToken, BOB, 100_000);
        _fundOn(feeCore, feeToken, address(this), 100_000);

        vm.prank(ALICE);
        feeCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(BOB);
        feeCore.take(IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC);

        vm.prank(ALICE);
        feeCore.settle(IOrderBookCore.Side.Ask, 100);

        feeCore.take(IOrderBookCore.Side.Bid, 100, 20, IOrderBookCore.FillPolicy.IOC);

        vm.prank(ALICE);
        feeCore.settle(IOrderBookCore.Side.Ask, 100);

        assertEq(feeCore.accountEquity(ALICE), 100_003, "partial-settlement maker rebate accounting");
        assertEq(feeCore.protocolFeesAccrued(), 3, "protocol fees across partial fills");

        vm.prank(ALICE);
        feeCore.settle(IOrderBookCore.Side.Ask, 100);

        assertEq(feeCore.accountEquity(ALICE), 100_003, "repeated settle duplicated rebate");
        assertEq(feeCore.protocolFeesAccrued(), 3, "repeated settle duplicated protocol fee");
    }

    function testModuleCanReserveThenExecuteForAccount() public {
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 100);

        uint16 ceiling =
            core.moduleReserveExposure(ALICE, IOrderBookCore.Side.Bid, 50);
        assertEq(ceiling, 120, "module risk ceiling");

        uint96 filled = core.moduleTake(
            ALICE,
            IOrderBookCore.Side.Bid,
            110,
            50,
            IOrderBookCore.FillPolicy.IOC,
            false,
            true
        );

        assertEq(filled, 50, "module execution mismatch");
        assertEq(int256(_corePosition(ALICE)), 50, "module account position");
    }

    function testModuleRestingSharesCannotBeBurnedByGenericCancel() public {
        uint16 ceiling =
            core.moduleReserveExposure(ALICE, IOrderBookCore.Side.Bid, 50);

        uint128 shares = core.moduleAddLiquidity(
            ALICE,
            IOrderBookCore.Side.Bid,
            99,
            50,
            ceiling
        );

        vm.prank(ALICE);
        (bool genericCancel,) = address(core).call(
            abi.encodeCall(
                core.removeShares,
                (IOrderBookCore.Side.Bid, uint16(99), shares)
            )
        );
        assertTrue(!genericCancel, "generic cancel burned module-owned shares");

        (,, uint32 generation) = core.pools(IOrderBookCore.Side.Bid, 99);

        uint96 removed = core.moduleRemoveLockedShares(
            ALICE,
            IOrderBookCore.Side.Bid,
            99,
            generation,
            shares
        );

        assertEq(removed, 50, "module cancellation lots");

    }

    function testProfitableFlatAccountCanWithdrawRealizedTradingPnL() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);

        vm.prank(BOB);
        core.take(IOrderBookCore.Side.Bid, 100, 10, IOrderBookCore.FillPolicy.IOC);

        core.addLiquidity(IOrderBookCore.Side.Bid, 110, 10);

        vm.prank(BOB);
        core.take(IOrderBookCore.Side.Ask, 110, 10, IOrderBookCore.FillPolicy.IOC);

        assertEq(core.accountEquity(BOB), 100_100, "round-trip profit not reflected in equity");

        vm.prank(BOB);
        core.withdrawCollateral(100_100);

        assertEq(token.balanceOf(BOB), 100_100, "realized trading profit not withdrawable");
        assertEq(core.accountEquity(BOB), 0, "withdrawal did not debit internal cash");
    }

    function testNewRiskUsesAccountEquityRatherThanDepositLedger() public {
        MockERC20 lossToken = new MockERC20();
        MockMarkOracle lossOracle = new MockMarkOracle(100);
        OrderBookCore lossCore =
            new OrderBookCore(address(lossToken), address(lossOracle), 20, 1_000, 0, 0);

        _fundOn(lossCore, lossToken, ALICE, 100_000);
        _fundOn(lossCore, lossToken, BOB, 1_000);

        vm.prank(ALICE);
        lossCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);

        vm.prank(BOB);
        lossCore.take(IOrderBookCore.Side.Bid, 100, 10, IOrderBookCore.FillPolicy.IOC);

        lossOracle.setMarkTick(50);
        assertEq(lossCore.accountEquity(BOB), 500, "marked loss not reflected in equity");

        vm.prank(BOB);
        (bool ok,) = address(lossCore).call(
            abi.encodeCall(
                lossCore.addLiquidity,
                (IOrderBookCore.Side.Bid, uint16(49), uint96(70))
            )
        );

        assertTrue(!ok, "risk-increasing quote admitted against stale deposit balance");
    }

    function testProtocolFeesCanBeAllocatedToInsurance() public {
        MockERC20 feeToken = new MockERC20();
        MockMarkOracle feeOracle = new MockMarkOracle(100);
        OrderBookCore feeCore =
            new OrderBookCore(address(feeToken), address(feeOracle), 20, 1_000, 10, 5);

        _fundOn(feeCore, feeToken, ALICE, 100_000);
        _fundOn(feeCore, feeToken, BOB, 100_000);

        vm.prank(ALICE);
        feeCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(BOB);
        feeCore.take(IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC);

        assertEq(feeCore.protocolFeesAccrued(), 2, "fee accrual mismatch");

        feeCore.allocateProtocolFeesToInsurance(2);

        assertEq(feeCore.protocolFeesAccrued(), 0, "protocol fee not allocated");
        assertEq(feeCore.insuranceReserves(), 2, "insurance reserve not credited");
    }

    function testInsuranceFundingUsesRealTokenCustody() public {
        token.mint(address(this), 5_000);
        core.fundInsurance(5_000);

        assertEq(core.insuranceReserves(), 5_000, "insurance accounting mismatch");
        assertEq(token.balanceOf(address(core)), 305_000, "insurance custody mismatch");
    }

    function testLiquidationRewardPaymentIsCappedByProtocolFees() public {
        MockERC20 feeToken = new MockERC20();
        MockMarkOracle feeOracle = new MockMarkOracle(100);
        OrderBookCore feeCore =
            new OrderBookCore(address(feeToken), address(feeOracle), 20, 1_000, 10, 5);

        feeCore.configureAdvancedModule(address(this));
        _fundOn(feeCore, feeToken, ALICE, 100_000);
        _fundOn(feeCore, feeToken, BOB, 100_000);

        vm.prank(ALICE);
        feeCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(BOB);
        feeCore.take(IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC);

        assertEq(feeCore.protocolFeesAccrued(), 2, "protocol fee setup mismatch");

        address liquidator = address(0x1A2B);
        uint256 paid = feeCore.modulePayLiquidationReward(liquidator, 10);

        assertEq(paid, 2, "reward not capped by protocol fees");
        assertEq(feeCore.protocolFeesAccrued(), 0, "protocol fees not debited");
        assertEq(feeToken.balanceOf(liquidator), 2, "liquidator did not receive reward");
    }

    function testAccountingUnitScaleNormalizesMarginAndFees() public {
        MockERC20 unitToken = new MockERC20();
        MockMarkOracle unitOracle = new MockMarkOracle(100);
        OrderBookCore unitCore =
            new OrderBookCore(address(unitToken), address(unitOracle), 20, 1_000, 10, 5);

        unitCore.configureAccountingUnitScale(1_000);
        assertEq(
            unitCore.notionalValue(10, 100),
            1_000_000,
            "normalized notional mismatch"
        );

        _fundOn(unitCore, unitToken, ALICE, 2_000_000);
        _fundOn(unitCore, unitToken, BOB, 2_000_000);

        vm.prank(ALICE);
        unitCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 10);

        vm.prank(BOB);
        unitCore.take(
            IOrderBookCore.Side.Bid,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(
            unitCore.accountEquity(BOB),
            1_999_000,
            "normalized taker fee/equity mismatch"
        );
        assertEq(
            unitCore.protocolFeesAccrued(),
            500,
            "normalized protocol fee mismatch"
        );
    }

    function testAccountingUnitScaleLocksWhenCustodyStarts() public {
        MockERC20 unitToken = new MockERC20();
        MockMarkOracle unitOracle = new MockMarkOracle(100);
        OrderBookCore unitCore =
            new OrderBookCore(address(unitToken), address(unitOracle), 20, 1_000, 0, 0);

        _fundOn(unitCore, unitToken, ALICE, 100_000);

        (bool ok,) = address(unitCore).call(
            abi.encodeCall(unitCore.configureAccountingUnitScale, (uint128(1_000)))
        );
        assertTrue(!ok, "accounting scale changed after custody started");
        assertEq(unitCore.notionalValue(10, 100), 1_000, "default scale changed");
    }

    function testNormalizedMarginRejectsUndercollateralizedQuote() public {
        MockERC20 unitToken = new MockERC20();
        MockMarkOracle unitOracle = new MockMarkOracle(100);
        OrderBookCore unitCore =
            new OrderBookCore(address(unitToken), address(unitOracle), 20, 1_000, 0, 0);

        unitCore.configureAccountingUnitScale(1_000);
        _fundOn(unitCore, unitToken, ALICE, 100_000);

        vm.prank(ALICE);
        unitCore.addLiquidity(IOrderBookCore.Side.Bid, 99, 8);

        vm.prank(ALICE);
        (bool ok,) = address(unitCore).call(
            abi.encodeCall(
                unitCore.addLiquidity,
                (IOrderBookCore.Side.Bid, uint16(98), uint96(3))
            )
        );
        assertTrue(!ok, "normalized margin admitted excess quote");
    }

    function testRiskCeilingClearsWhenReachableExposureCollapses() public {
        MockERC20 riskToken = new MockERC20();
        MockMarkOracle riskOracle = new MockMarkOracle(100);
        OrderBookCore riskCore =
            new OrderBookCore(address(riskToken), address(riskOracle), 20, 1_000, 0, 0);

        _fundOn(riskCore, riskToken, ALICE, 600);

        vm.prank(ALICE);
        riskCore.addLiquidity(IOrderBookCore.Side.Bid, 99, 50);

        vm.prank(ALICE);
        (uint128 shares,,) = riskCore.quotes(
            ALICE,
            IOrderBookCore.Side.Bid,
            99
        );

        vm.prank(ALICE);
        riskCore.removeShares(IOrderBookCore.Side.Bid, 99, shares);

        (int80 settled, int80 minPosition, int80 maxPosition) =
            riskCore.accountRisk(ALICE);
        assertEq(int256(settled), int256(minPosition), "min envelope not collapsed");
        assertEq(int256(settled), int256(maxPosition), "max envelope not collapsed");

        riskOracle.setMarkTick(50);

        // New requirement is 80 * (50 + 20) * 10% = 560.
        // A stale historical ceiling of 120 would require 960 and reject this.
        vm.prank(ALICE);
        riskCore.addLiquidity(IOrderBookCore.Side.Bid, 49, 80);
    }

    function testWithdrawalBlockedUntilLazyMakerFillIsSettled() public {
        MockERC20 lazyToken = new MockERC20();
        MockMarkOracle lazyOracle = new MockMarkOracle(100);
        OrderBookCore lazyCore =
            new OrderBookCore(address(lazyToken), address(lazyOracle), 20, 1_000, 10, 5);

        _fundOn(lazyCore, lazyToken, ALICE, 100_000);
        _fundOn(lazyCore, lazyToken, BOB, 100_000);

        vm.prank(ALICE);
        lazyCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(BOB);
        lazyCore.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(lazyCore.activeQuoteCount(ALICE), 1, "lazy quote unexpectedly settled");

        vm.prank(ALICE);
        (bool beforeSettleOk,) = address(lazyCore).call(
            abi.encodeCall(lazyCore.withdrawCollateral, (uint256(1)))
        );
        assertTrue(!beforeSettleOk, "maker withdrew against unsettled lazy fill");

        vm.prank(ALICE);
        lazyCore.settle(IOrderBookCore.Side.Ask, 100);

        assertEq(lazyCore.activeQuoteCount(ALICE), 0, "settle did not retire lazy quote");

        uint256 reserved = lazyCore.reservedMargin(ALICE);
        uint256 withdrawable = uint256(lazyCore.accountEquity(ALICE)) - reserved;

        vm.prank(ALICE);
        lazyCore.withdrawCollateral(withdrawable);

        assertEq(
            lazyCore.accountEquity(ALICE),
            int256(reserved),
            "withdrawal did not preserve open-position margin"
        );
    }

    function testWithdrawalBlockedUntilLazyFundingIsMaterializedWithMakerFill() public {
        MockERC20 lazyToken = new MockERC20();
        MockMarkOracle lazyOracle = new MockMarkOracle(100);
        OrderBookCore lazyCore =
            new OrderBookCore(address(lazyToken), address(lazyOracle), 20, 1_000, 0, 0);

        _fundOn(lazyCore, lazyToken, ALICE, 100_000);
        _fundOn(lazyCore, lazyToken, BOB, 100_000);

        vm.prank(ALICE);
        lazyCore.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(BOB);
        lazyCore.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        lazyCore.setFundingIndex(int128(3e18));

        vm.prank(ALICE);
        (bool beforeSettleOk,) = address(lazyCore).call(
            abi.encodeCall(lazyCore.withdrawCollateral, (uint256(1)))
        );
        assertTrue(!beforeSettleOk, "maker withdrew before lazy funding settlement");

        vm.prank(ALICE);
        lazyCore.settle(IOrderBookCore.Side.Ask, 100);

        assertEq(
            lazyCore.accountEquity(ALICE),
            100_300,
            "maker funding not materialized at settlement"
        );

        uint256 reserved = lazyCore.reservedMargin(ALICE);
        uint256 withdrawable = uint256(lazyCore.accountEquity(ALICE)) - reserved;

        vm.prank(ALICE);
        lazyCore.withdrawCollateral(withdrawable);
        assertEq(
            lazyCore.accountEquity(ALICE),
            int256(reserved),
            "funded maker withdrawal did not preserve open-position margin"
        );
    }

    function testFundingUpdaterCanBeRotatedWithoutChangingOwner() public {
        address updater = address(0xF00D);

        core.setFundingUpdater(updater);
        assertTrue(core.fundingUpdater() == updater, "funding updater not rotated");

        (bool oldUpdaterOk,) =
            address(core).call(abi.encodeCall(core.setFundingIndex, (int128(1e18))));
        assertTrue(!oldUpdaterOk, "old updater retained funding authority");

        vm.prank(updater);
        core.setFundingIndex(int128(1e18));

        core.setFundingUpdater(address(this));
        core.setFundingIndex(int128(2e18));
    }

    function testAdvancedModuleCanOnlyBeConfiguredOnce() public {
        (bool ok,) =
            address(core).call(abi.encodeCall(core.configureAdvancedModule, (address(0x1234))));
        assertTrue(!ok, "advanced module was replaceable");
    }
    function _fundOn(
        OrderBookCore target,
        MockERC20 targetToken,
        address account,
        uint256 amount
    ) internal {
        targetToken.mint(account, amount);
        vm.prank(account);
        targetToken.approve(address(target), type(uint256).max);
        vm.prank(account);
        target.depositCollateral(amount);
    }

    function _corePosition(address account) internal view returns (int80 position) {
        (position,,) = core.accountRisk(account);
    }

}

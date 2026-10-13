// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract AccountingConservationPropertyTest is TestBase {
    OrderBookCoreHarness internal core;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant TAKER = address(0x7A6E2);

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core =
            new OrderBookCoreHarness(address(token), address(oracle), 40, 1_000, 10, 5);

        core.configureAccountingUnitScale(1_000);

        _fund(ALICE, 10_000_000);
        _fund(BOB, 10_000_000);
        _fund(CAROL, 10_000_000);
        _fund(TAKER, 10_000_000);
    }

    function testFuzz_InternalClaimsNeverExceedTokenCustodyAfterSettlement(
        uint256 aliceSeed,
        uint256 bobSeed,
        uint256 carolSeed,
        uint256 fillSeed
    ) public {
        uint96 aliceLots = boundNonZero(aliceSeed, 700);
        uint96 bobLots = boundNonZero(bobSeed, 700);
        uint96 carolLots = boundNonZero(carolSeed, 700);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, aliceLots);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, bobLots);
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, carolLots);

        uint256 totalLots =
            uint256(aliceLots) + uint256(bobLots) + uint256(carolLots);
        uint256 maxSafeTakerLots = totalLots < 450 ? totalLots : 450;
        uint96 requested = uint96((fillSeed % maxSafeTakerLots) + 1);

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            requested,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);
        vm.prank(BOB);
        core.settle(IOrderBookCore.Side.Ask, 105);
        vm.prank(CAROL);
        core.settle(IOrderBookCore.Side.Ask, 105);

        int256 userClaims =
            _cashClaim(ALICE) + _cashClaim(BOB) + _cashClaim(CAROL)
                + _cashClaim(TAKER);
        assertTrue(userClaims >= 0, "aggregate user cash claim negative");

        uint256 protocolClaims =
            core.protocolFeesAccrued() + core.insuranceReserves();
        uint256 totalClaims = uint256(userClaims) + protocolClaims;
        uint256 custody = token.balanceOf(address(core));

        assertTrue(totalClaims <= custody, "internal claims exceed token custody");
    }

    function testDeferredMakerCreditsAreAbsentFromRealizedAggregateUntilSettlement() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 100);

        int256 beforeFill = core.realizedCashflowTotalTest();
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 105, 40, IOrderBookCore.FillPolicy.IOC);

        (,, int256 makerFundingBefore,,) = core.accountingStateTest(ALICE);
        assertEq(makerFundingBefore, 0, "maker funding should remain unsettled");
        int256 pendingAggregate = core.realizedCashflowTotalTest();
        assertTrue(pendingAggregate < beforeFill, "taker paid before maker settlement");

        // Gross token custody has not changed during the trade; the missing
        // maker leg is a liability, not spendable protocol-fee surplus.
        uint256 custody = token.balanceOf(address(core));
        assertEq(custody, 40_000_000, "trade should not move custody");
        assertEq(core.protocolFeesAccrued(), 2_100, "net protocol fee");

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);

        int256 settledAggregate = core.realizedCashflowTotalTest();
        assertTrue(settledAggregate > pendingAggregate, "maker settlement should credit maker");
        assertEq(settledAggregate + int256(core.protocolFeesAccrued()), 0,
            "settled maker and taker cash plus protocol fees must conserve");
        assertEq(token.balanceOf(address(core)), custody, "settlement moved custody");
    }

    function testPendingMakerExecutionNotionalClearsOnSettlement() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 100);

        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 105, 40, IOrderBookCore.FillPolicy.IOC);

        int256 notional = int256(core.notionalValue(40, 105));
        assertEq(core.pendingMakerTradeCashflowTest(), notional,
            "unsettled ask notional missing");

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);

        assertEq(core.pendingMakerTradeCashflowTest(), 0,
            "maker settlement did not release pending notional");
    }

    function testPendingBidExecutionNotionalClearsOnSettlement() public {
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 100);

        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Ask, 95, 40, IOrderBookCore.FillPolicy.IOC);

        int256 notional = int256(core.notionalValue(40, 95));
        assertEq(core.pendingMakerTradeCashflowTest(), -notional,
            "unsettled bid notional sign drift");

        vm.prank(BOB);
        core.settle(IOrderBookCore.Side.Bid, 95);

        assertEq(core.pendingMakerTradeCashflowTest(), 0,
            "bid maker settlement did not release pending notional");
    }

    function testPendingMakerFundingEntryReconcilesAcrossSettlement() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 100);
        core.setFundingIndex(int128(1e17));

        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 105, 40, IOrderBookCore.FillPolicy.IOC);

        (uint96 pendingLots, int256 entry) =
            core.makerResidualTest(IOrderBookCore.Side.Ask, 105, 0);
        assertEq(uint256(pendingLots), 40, "unexpected pending maker lots");
        assertEq(core.pendingMakerFundingEntryTest(), entry,
            "execution funding entry missing from aggregate");

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);

        (, int256 remaining) = core.makerResidualTest(IOrderBookCore.Side.Ask, 105, 0);
        assertEq(core.pendingMakerFundingEntryTest(), remaining,
            "aggregate diverged from generation funding entry");
    }

    function testPositionFundingIsPendingUntilAccountSettlement() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 105, 40, IOrderBookCore.FillPolicy.IOC);
        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);

        int256 realizedBefore = core.realizedCashflowTotalTest();
        uint256 custodyBefore = token.balanceOf(address(core));
        core.setFundingIndex(int128(1e17));

        // Funding publication does not touch settled account ledgers.
        assertEq(core.realizedCashflowTotalTest(), realizedBefore,
            "funding publication materialized accounts");
        assertEq(token.balanceOf(address(core)), custodyBefore,
            "funding publication moved collateral");

        (,, int256 makerBefore,,) = core.accountingStateTest(ALICE);
        (,, int256 takerBefore,,) = core.accountingStateTest(TAKER);
        core.settlePositionFundingTest(ALICE);
        core.settlePositionFundingTest(TAKER);
        (,, int256 makerAfter,,) = core.accountingStateTest(ALICE);
        (,, int256 takerAfter,,) = core.accountingStateTest(TAKER);

        assertTrue(makerAfter != makerBefore, "maker funding did not crystallize");
        assertTrue(takerAfter != takerBefore, "taker funding did not crystallize");
        assertEq(core.realizedCashflowTotalTest(),
            realizedBefore + makerAfter - makerBefore + takerAfter - takerBefore,
            "realized aggregate missing crystallized position funding");
        assertEq(token.balanceOf(address(core)), custodyBefore,
            "funding settlement moved collateral");
    }

    function _cashClaim(address account) internal view returns (int256 claim) {
        (uint256 collateral, int256 trading, int256 funding,,) =
            core.accountingStateTest(account);
        claim = int256(collateral) + trading + funding;
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }
}

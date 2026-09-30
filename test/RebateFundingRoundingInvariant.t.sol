// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract RebateFundingRoundingInvariantTest is TestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant TAKER = address(0x7A6E2);

    function testFuzz_ClosedGenerationSettlementOrderDoesNotChangeAggregateClaims(
        uint256 aSeed,
        uint256 bSeed,
        uint256 cSeed,
        uint256 fundingSeed
    ) public {
        uint96 aLots = boundNonZero(aSeed, 500);
        uint96 bLots = boundNonZero(bSeed, 500);
        uint96 cLots = boundNonZero(cSeed, 500);
        int128 fundingIndex = int128(int256((fundingSeed % 9) + 1) * 1e18);

        (
            uint256 claimsForward,
            uint256 protocolForward,
            int256 aggregateEquityForward
        ) = _runScenario(aLots, bLots, cLots, fundingIndex, false);

        (
            uint256 claimsReverse,
            uint256 protocolReverse,
            int256 aggregateEquityReverse
        ) = _runScenario(aLots, bLots, cLots, fundingIndex, true);

        assertEq(claimsForward, claimsReverse, "settlement order changed maker cash claims");
        assertEq(protocolForward, protocolReverse, "settlement order changed protocol fees");
        assertEq(
            aggregateEquityForward,
            aggregateEquityReverse,
            "settlement order changed aggregate marked equity"
        );
    }

    function testClosedGenerationSettlementIsIdempotentForRebateAndFunding() public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 105, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 40, 1_000, 10, 5
        );

        _fund(core, token, ALICE);
        _fund(core, token, TAKER);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 100);

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        core.setFundingIndex(int128(4e18));

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);

        (uint256 collateralBefore, int256 tradingBefore, int256 fundingBefore,,) =
            core.accountingStateTest(ALICE);
        (int80 positionBefore,,) = core.accountRisk(ALICE);
        uint256 protocolBefore = core.protocolFeesAccrued();

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);

        (uint256 collateralAfter, int256 tradingAfter, int256 fundingAfter,,) =
            core.accountingStateTest(ALICE);
        (int80 positionAfter,,) = core.accountRisk(ALICE);

        assertEq(collateralAfter, collateralBefore, "repeat settle changed collateral");
        assertEq(tradingAfter, tradingBefore, "repeat settle changed trading cashflow");
        assertEq(fundingAfter, fundingBefore, "repeat settle changed funding cashflow");
        assertEq(int256(positionAfter), int256(positionBefore), "repeat settle changed position");
        assertEq(core.protocolFeesAccrued(), protocolBefore, "repeat settle changed protocol fees");
    }

    function testBurnAttributedFillRealizesMakerRebateExactlyOnce() public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 10_000, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 100, 1_000, 10, 5
        );

        _fund(core, token, ALICE);
        _fund(core, token, BOB);
        _fund(core, token, TAKER);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 10_000, 1);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 10_000, 2);

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Bid,
            10_000,
            1,
            IOrderBookCore.FillPolicy.IOC
        );

        assertEq(core.protocolFeesAccrued(), 5, "net protocol fee reserve mismatch");

        vm.prank(ALICE);
        (uint128 aliceShares,,) =
            core.quotes(ALICE, IOrderBookCore.Side.Ask, 10_000);

        vm.prank(ALICE);
        uint96 removed =
            core.removeShares(IOrderBookCore.Side.Ask, 10_000, aliceShares);

        assertEq(removed, 0, "rounding burn redeemed pool liquidity");
        assertEq(core.protocolFeesAccrued(), 5, "maker rebate was charged twice");

        (uint256 aliceCollateral, int256 aliceTrading,,,) =
            core.accountingStateTest(ALICE);
        assertEq(aliceCollateral, 10_000_000, "maker collateral changed");
        assertEq(
            aliceTrading,
            10_005,
            "burn-attributed fill did not realize exactly one maker rebate"
        );

        (int80 alicePosition,,) = core.accountRisk(ALICE);
        assertEq(int256(alicePosition), -1, "burn-attributed maker position mismatch");

        uint256 aggregateClaims =
            _cashClaim(core, ALICE) + _cashClaim(core, BOB)
                + _cashClaim(core, TAKER) + core.protocolFeesAccrued();
        assertEq(
            aggregateClaims,
            30_000_000,
            "burn-attributed rebate broke custody claim conservation"
        );

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 10_000);
        (, int256 tradingAfterRepeat,,,) =
            core.accountingStateTest(ALICE);
        assertEq(
            tradingAfterRepeat,
            aliceTrading,
            "repeat settlement duplicated burn-attributed rebate"
        );
        assertEq(core.protocolFeesAccrued(), 5, "repeat settle changed protocol fees");
    }

    function testPureShareCancellationDoesNotRealizeMakerRebate() public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 10_000, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 100, 1_000, 10, 5
        );

        _fund(core, token, ALICE);
        _fund(core, token, BOB);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 10_000, 1);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 10_000, 2);

        vm.prank(ALICE);
        (uint128 aliceShares,,) =
            core.quotes(ALICE, IOrderBookCore.Side.Ask, 10_000);

        vm.prank(ALICE);
        uint96 removed =
            core.removeShares(IOrderBookCore.Side.Ask, 10_000, aliceShares);

        assertEq(removed, 1, "pure cancellation removed wrong lots");
        assertEq(core.protocolFeesAccrued(), 0, "pure cancellation changed protocol fees");

        (, int256 aliceTrading,,,) = core.accountingStateTest(ALICE);
        assertEq(aliceTrading, 0, "pure cancellation created maker rebate");

        (int80 alicePosition,,) = core.accountRisk(ALICE);
        assertEq(int256(alicePosition), 0, "pure cancellation created maker fill");
    }

    function testFuzz_RebateAndFundingRoundingNeverCreateClaims(
        uint256 aSeed,
        uint256 bSeed,
        uint256 cSeed,
        uint256 fundingSeed
    ) public {
        uint96 aLots = boundNonZero(aSeed, 1_000);
        uint96 bLots = boundNonZero(bSeed, 1_000);
        uint96 cLots = boundNonZero(cSeed, 1_000);
        int128 fundingIndex =
            int128(int256((fundingSeed % 19) + 1) * 1e18);

        (
            uint256 settledClaims,
            uint256 protocolClaims,
            int256 aggregateEquity
        ) = _runScenario(aLots, bLots, cLots, fundingIndex, false);

        uint256 initialCustody = 40_000_000;
        assertTrue(
            settledClaims + protocolClaims <= initialCustody,
            "rebate/funding rounding created token claims"
        );
        assertTrue(
            aggregateEquity + int256(protocolClaims) <= int256(initialCustody),
            "rebate/funding rounding created marked equity"
        );
    }

    function _runScenario(
        uint96 aLots,
        uint96 bLots,
        uint96 cLots,
        int128 fundingIndex,
        bool reverse
    )
        internal
        returns (
            uint256 settledClaims,
            uint256 protocolClaims,
            int256 aggregateEquity
        )
    {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 105, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 40, 1_000, 10, 5
        );

        _fund(core, token, ALICE);
        _fund(core, token, BOB);
        _fund(core, token, CAROL);
        _fund(core, token, TAKER);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, aLots);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, bLots);
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, cLots);

        uint96 totalLots =
            uint96(uint256(aLots) + uint256(bLots) + uint256(cLots));

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            totalLots,
            IOrderBookCore.FillPolicy.IOC
        );

        core.setFundingIndex(fundingIndex);

        if (reverse) {
            vm.prank(CAROL);
            core.settle(IOrderBookCore.Side.Ask, 105);
            vm.prank(BOB);
            core.settle(IOrderBookCore.Side.Ask, 105);
            vm.prank(ALICE);
            core.settle(IOrderBookCore.Side.Ask, 105);
        } else {
            vm.prank(ALICE);
            core.settle(IOrderBookCore.Side.Ask, 105);
            vm.prank(BOB);
            core.settle(IOrderBookCore.Side.Ask, 105);
            vm.prank(CAROL);
            core.settle(IOrderBookCore.Side.Ask, 105);
        }

        settledClaims =
            _cashClaim(core, ALICE) + _cashClaim(core, BOB)
                + _cashClaim(core, CAROL) + _cashClaim(core, TAKER);
        protocolClaims = core.protocolFeesAccrued();
        aggregateEquity =
            core.accountEquity(ALICE) + core.accountEquity(BOB)
                + core.accountEquity(CAROL) + core.accountEquity(TAKER);
    }

    function _cashClaim(OrderBookCoreHarness core, address account)
        internal
        view
        returns (uint256 claim)
    {
        (uint256 collateral, int256 trading, int256 funding,,) =
            core.accountingStateTest(account);
        int256 signedClaim = int256(collateral) + trading + funding;
        assertTrue(signedClaim >= 0, "negative settled cash claim");
        claim = uint256(signedClaim);
    }

    function _fund(
        OrderBookCoreHarness core,
        MockERC20 token,
        address account
    ) internal {
        token.mint(account, 10_000_000);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(10_000_000);
    }
}

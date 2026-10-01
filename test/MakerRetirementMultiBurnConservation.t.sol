// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

/// @notice Repeated partial maker retirements must not manufacture executed lots or claims.
contract MakerRetirementMultiBurnConservationTest is TestBase {
    address internal constant MAKER0 = address(0xA0);
    address internal constant MAKER1 = address(0xA1);
    address internal constant MAKER2 = address(0xA2);
    address internal constant TAKER = address(0xB0);
    uint16 internal constant TICK = 10_000;

    function testRegression_PureCancellationTransfersPendingFundingBasis() public {
        testFuzz_MultiBurnsNeverOverCreditMakerExecution(
            44,
            3,
            37,
            3,
            13,
            11,
            68,
            16
        );
    }

    function testRegression_ZeroLotBurnCannotPromoteCeilClaim() public {
        testFuzz_MultiBurnsNeverOverCreditMakerExecution(
            1658430977897,
            1,
            212521579167430931844821027961619,
            779,
            393529077688649832194399472615527365759349911498915169967130266704,
            929033019645645257543618256479030637142708,
            1,
            1353047529533353940640803025083638372
        );
    }

    function testRegression_FinalMakerCanRetireUnownedPoolDust() public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), TICK, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 100, 1_000, 10, 5
        );

        _fund(core, token, MAKER0);
        _fund(core, token, MAKER1);
        _fund(core, token, TAKER);

        _add(core, MAKER0, 78);
        _add(core, MAKER1, 1);

        // Retiring the tiny maker can leave conservative cancellation dust in
        // the pool denominator without assigning it to MAKER0's canonical claim.
        vm.prank(MAKER1);
        (uint128 smallShares,,) =
            core.quotes(MAKER1, IOrderBookCore.Side.Ask, TICK);
        core.removeShares(IOrderBookCore.Side.Ask, TICK, smallShares);

        (uint128 finalShares, uint96 finalClaim,) =
            core.quotes(MAKER0, IOrderBookCore.Side.Ask, TICK);
        (, uint96 poolRemaining,) =
            core.pools(IOrderBookCore.Side.Ask, TICK);

        assertTrue(poolRemaining >= finalClaim, "pool below canonical claim");

        vm.prank(MAKER0);
        core.removeShares(IOrderBookCore.Side.Ask, TICK, finalShares);

        (uint128 totalShares, uint96 remainingLots,) =
            core.pools(IOrderBookCore.Side.Ask, TICK);
        assertEq(uint256(totalShares), 0, "final shares remained");
        assertEq(uint256(remainingLots), 0, "unowned dust remained");
        assertEq(
            int256(_position(core, MAKER0)),
            int256(0),
            "dust retirement created maker execution"
        );
        _assertRiskEnvelope(core, MAKER0);
    }

    function testFuzz_MultiBurnsNeverOverCreditMakerExecution(
        uint256 maker0Seed,
        uint256 maker1Seed,
        uint256 maker2Seed,
        uint256 firstFillSeed,
        uint256 secondFillSeed,
        uint256 burn0Seed,
        uint256 burn1Seed,
        uint256 fundingSeed
    ) public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), TICK, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 100, 1_000, 10, 5
        );

        _fund(core, token, MAKER0);
        _fund(core, token, MAKER1);
        _fund(core, token, MAKER2);
        _fund(core, token, TAKER);

        uint96 maker0Lots = boundNonZero(maker0Seed, 120);
        uint96 maker1Lots = boundNonZero(maker1Seed, 120);
        uint96 maker2Lots = boundNonZero(maker2Seed, 120);

        _add(core, MAKER0, maker0Lots);
        _add(core, MAKER1, maker1Lots);
        _add(core, MAKER2, maker2Lots);

        (, uint96 initialRemaining,) =
            core.pools(IOrderBookCore.Side.Ask, TICK);
        uint96 firstFill =
            uint96(firstFillSeed % (uint256(initialRemaining) + 1));
        _take(core, firstFill);

        int128 fundingA =
            int128((int256(fundingSeed % 17) - 8) * 1e18);
        int128 fundingB = fundingA + int128(5e18);
        core.setFundingIndex(fundingA);

        _burnPartial(core, MAKER0, burn0Seed);

        (, uint96 remainingAfterFirstBurn,) =
            core.pools(IOrderBookCore.Side.Ask, TICK);
        uint96 secondFill =
            uint96(secondFillSeed % (uint256(remainingAfterFirstBurn) + 1));
        _take(core, secondFill);

        core.setFundingIndex(fundingB);
        _burnPartial(core, MAKER1, burn1Seed);

        (, uint96 finalRestingLots,) =
            core.pools(IOrderBookCore.Side.Ask, TICK);
        _take(core, finalRestingLots);

        _settle(core, MAKER0);
        _settle(core, MAKER1);
        _settle(core, MAKER2);

        vm.prank(TAKER);
        core.settle(IOrderBookCore.Side.Bid, TICK);

        int256 makerPosition =
            int256(_position(core, MAKER0))
                + int256(_position(core, MAKER1))
                + int256(_position(core, MAKER2));
        int256 takerPosition = int256(_position(core, TAKER));
        int256 roundingDebt = makerPosition + takerPosition;

        assertTrue(
            roundingDebt >= 0,
            "multi-burn retirement over-credited maker execution"
        );
        assertEq(
            takerPosition,
            int256(uint256(firstFill) + uint256(secondFill) + uint256(finalRestingLots)),
            "taker position diverged from executed lots"
        );

        _assertRiskEnvelope(core, MAKER0);
        _assertRiskEnvelope(core, MAKER1);
        _assertRiskEnvelope(core, MAKER2);
        _assertRiskEnvelope(core, TAKER);

        uint256 claims =
            _cashClaim(core, MAKER0) + _cashClaim(core, MAKER1)
                + _cashClaim(core, MAKER2) + _cashClaim(core, TAKER)
                + core.protocolFeesAccrued();

        assertTrue(
            claims <= token.balanceOf(address(core)),
            "multi-burn retirement created unbacked token claims"
        );
    }

    function _burnPartial(
        OrderBookCoreHarness core,
        address maker,
        uint256 seed
    ) internal {
        (uint128 shares,, uint32 quoteGeneration) =
            core.quotes(maker, IOrderBookCore.Side.Ask, TICK);
        (, , uint32 poolGeneration) =
            core.pools(IOrderBookCore.Side.Ask, TICK);

        if (shares == 0 || quoteGeneration != poolGeneration) return;

        uint128 burnShares;
        if (shares == 1) {
            burnShares = 1;
        } else {
            burnShares =
                uint128((uint256(shares) * ((seed % 79) + 1)) / 100);
            if (burnShares == 0) burnShares = 1;
            if (burnShares >= shares) burnShares = shares - 1;
        }

        vm.prank(maker);
        core.removeShares(IOrderBookCore.Side.Ask, TICK, burnShares);
    }

    function _take(OrderBookCoreHarness core, uint96 lots) internal {
        if (lots == 0) return;

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Bid,
            TICK,
            lots,
            IOrderBookCore.FillPolicy.IOC
        );
    }

    function _settle(OrderBookCoreHarness core, address maker) internal {
        vm.prank(maker);
        core.settle(IOrderBookCore.Side.Ask, TICK);
    }

    function _assertRiskEnvelope(OrderBookCoreHarness core, address account)
        internal
        view
    {
        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(account);
        assertTrue(minPosition <= settled, "settled below min");
        assertTrue(settled <= maxPosition, "settled above max");
    }

    function _position(OrderBookCoreHarness core, address account)
        internal
        view
        returns (int80 position)
    {
        (position,,) = core.accountRisk(account);
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

    function _add(
        OrderBookCoreHarness core,
        address maker,
        uint96 lots
    ) internal {
        vm.prank(maker);
        core.addLiquidity(IOrderBookCore.Side.Ask, TICK, lots);
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

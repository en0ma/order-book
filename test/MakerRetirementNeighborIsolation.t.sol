// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {OrderBookMath} from "../src/deployable/OrderBookMath.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

/// @notice Partial maker retirement must not corrupt neighboring maker ownership.
/// @dev Neighbor claims may move only as implied by canonical ceil pro-rata rounding.
contract MakerRetirementNeighborIsolationTest is TestBase {
    address internal constant TARGET = address(0xA0);
    address internal constant NEIGHBOR0 = address(0xA1);
    address internal constant NEIGHBOR1 = address(0xA2);
    address internal constant TAKER = address(0xB0);

    uint16 internal constant TICK = 10_000;

    function testFuzz_PartialBurnPreservesNeighborSharesAndCanonicalClaims(
        uint256 targetSeed,
        uint256 neighbor0Seed,
        uint256 neighbor1Seed,
        uint256 fillSeed,
        uint256 burnSeed,
        uint256 fundingSeed
    ) public {
        uint96 targetLots = boundNonZero(targetSeed, 120);
        uint96 neighbor0Lots = boundNonZero(neighbor0Seed, 120);
        uint96 neighbor1Lots = boundNonZero(neighbor1Seed, 120);
        uint96 totalLots = targetLots + neighbor0Lots + neighbor1Lots;
        uint96 fillLots = uint96(fillSeed % uint256(totalLots));
        int128 fundingIndex =
            int128((int256(fundingSeed % 17) - 8) * 1e18);

        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), TICK, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 100, 1_000, 10, 5
        );

        _fund(core, token, TARGET);
        _fund(core, token, NEIGHBOR0);
        _fund(core, token, NEIGHBOR1);
        _fund(core, token, TAKER);

        _add(core, TARGET, targetLots);
        _add(core, NEIGHBOR0, neighbor0Lots);
        _add(core, NEIGHBOR1, neighbor1Lots);

        if (fillLots != 0) {
            vm.prank(TAKER);
            core.take(
                IOrderBookCore.Side.Bid,
                TICK,
                fillLots,
                IOrderBookCore.FillPolicy.IOC
            );
        }

        core.setFundingIndex(fundingIndex);

        (uint128 targetShares,,) =
            core.quotes(TARGET, IOrderBookCore.Side.Ask, TICK);
        (uint128 n0SharesBefore,,) =
            core.quotes(NEIGHBOR0, IOrderBookCore.Side.Ask, TICK);
        (uint128 n1SharesBefore,,) =
            core.quotes(NEIGHBOR1, IOrderBookCore.Side.Ask, TICK);

        uint128 burnShares = _partialBurn(targetShares, burnSeed);

        vm.prank(TARGET);
        core.removeShares(IOrderBookCore.Side.Ask, TICK, burnShares);

        (uint128 totalSharesAfter, uint96 remainingAfter,) =
            core.pools(IOrderBookCore.Side.Ask, TICK);

        _assertNeighborQuote(
            core,
            NEIGHBOR0,
            n0SharesBefore,
            totalSharesAfter,
            remainingAfter
        );
        _assertNeighborQuote(
            core,
            NEIGHBOR1,
            n1SharesBefore,
            totalSharesAfter,
            remainingAfter
        );

        _assertRiskEnvelope(core, TARGET);
        _assertRiskEnvelope(core, NEIGHBOR0);
        _assertRiskEnvelope(core, NEIGHBOR1);

        uint96 remainingToTake = remainingAfter;
        if (remainingToTake != 0) {
            vm.prank(TAKER);
            core.take(
                IOrderBookCore.Side.Bid,
                TICK,
                remainingToTake,
                IOrderBookCore.FillPolicy.IOC
            );
        }

        vm.prank(TARGET);
        core.settle(IOrderBookCore.Side.Ask, TICK);
        vm.prank(NEIGHBOR0);
        core.settle(IOrderBookCore.Side.Ask, TICK);
        vm.prank(NEIGHBOR1);
        core.settle(IOrderBookCore.Side.Ask, TICK);
        vm.prank(TAKER);
        core.settle(IOrderBookCore.Side.Bid, TICK);

        (int80 targetPosition,,) = core.accountRisk(TARGET);
        (int80 n0Position,,) = core.accountRisk(NEIGHBOR0);
        (int80 n1Position,,) = core.accountRisk(NEIGHBOR1);
        (int80 takerPosition,,) = core.accountRisk(TAKER);

        assertEq(
            int256(targetPosition) + int256(n0Position) + int256(n1Position)
                + int256(takerPosition),
            0,
            "partial retirement broke position conservation"
        );

        uint256 claims =
            _cashClaim(core, TARGET) + _cashClaim(core, NEIGHBOR0)
                + _cashClaim(core, NEIGHBOR1) + _cashClaim(core, TAKER)
                + core.protocolFeesAccrued();

        assertTrue(
            claims <= token.balanceOf(address(core)),
            "partial retirement created token claims"
        );
    }

    function _assertNeighborQuote(
        OrderBookCoreHarness core,
        address maker,
        uint128 expectedShares,
        uint128 totalShares,
        uint96 remainingLots
    ) internal {
        (uint128 sharesBefore,,) =
            core.quotes(maker, IOrderBookCore.Side.Ask, TICK);

        assertEq(
            uint256(sharesBefore),
            uint256(expectedShares),
            "neighbor shares changed"
        );

        uint96 canonicalClaim =
            OrderBookMath.redeemableLotsCeil(
                sharesBefore,
                remainingLots,
                totalShares
            );

        vm.prank(maker);
        core.settle(IOrderBookCore.Side.Ask, TICK);

        (uint128 sharesAfter, uint96 storedClaim,) =
            core.quotes(maker, IOrderBookCore.Side.Ask, TICK);

        assertEq(
            uint256(sharesAfter),
            uint256(expectedShares),
            "neighbor settlement changed shares"
        );
        assertEq(
            storedClaim,
            canonicalClaim,
            "neighbor settlement did not materialize canonical ceil claim"
        );
    }

    function _assertRiskEnvelope(OrderBookCoreHarness core, address account)
        internal
        view
    {
        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(account);
        assertTrue(minPosition <= settled, "risk min above settled");
        assertTrue(settled <= maxPosition, "risk settled above max");
    }

    function _partialBurn(uint128 shares, uint256 seed)
        internal
        pure
        returns (uint128 burn)
    {
        if (shares == 1) return 1;

        burn = uint128(
            (uint256(shares) * ((seed % 99) + 1)) / 100
        );
        if (burn == 0) burn = 1;
        if (burn >= shares) burn = shares - 1;
    }

    function _add(
        OrderBookCoreHarness core,
        address maker,
        uint96 lots
    ) internal {
        vm.prank(maker);
        core.addLiquidity(IOrderBookCore.Side.Ask, TICK, lots);
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract MakerAttributionPropertyTest is TestBase {
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
        core = new OrderBookCoreHarness(address(token), address(oracle), 40, 1_000, 0, 0);

        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
        _fund(TAKER);
    }

    function testFuzz_LazyMakerAttributionNeverOverCreditsAcrossLateJoins(
        uint256 aSeed,
        uint256 bSeed,
        uint256 cSeed,
        uint256 firstFillSeed,
        uint256 secondFillSeed
    ) public {
        uint96 aliceLots = boundNonZero(aSeed, 1_000);
        uint96 bobLots = boundNonZero(bSeed, 1_000);
        uint96 carolLots = boundNonZero(cSeed, 1_000);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, aliceLots);

        uint96 firstFill = uint96(firstFillSeed % (uint256(aliceLots) + 1));
        if (firstFill != 0) {
            vm.prank(TAKER);
            core.take(
                IOrderBookCore.Side.Bid,
                105,
                firstFill,
                IOrderBookCore.FillPolicy.IOC
            );
        }

        // BOB and CAROL join after the first fill, exercising share minting at
        // a non-initial pool exchange rate whenever Alice still has liquidity.
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, bobLots);
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, carolLots);

        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Ask, 105);
        uint96 secondFill =
            uint96(secondFillSeed % (uint256(remaining) + 1));

        if (secondFill != 0) {
            vm.prank(TAKER);
            core.take(
                IOrderBookCore.Side.Bid,
                105,
                secondFill,
                IOrderBookCore.FillPolicy.IOC
            );
        }

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);
        vm.prank(BOB);
        core.settle(IOrderBookCore.Side.Ask, 105);
        vm.prank(CAROL);
        core.settle(IOrderBookCore.Side.Ask, 105);

        int256 takerPosition = int256(_position(TAKER));
        int256 makerPosition =
            int256(_position(ALICE)) + int256(_position(BOB)) + int256(_position(CAROL));

        int256 roundingDebt = makerPosition + takerPosition;
        (uint96 residual0,) =
            core.makerResidualTest(IOrderBookCore.Side.Ask, 105, 0);
        (uint96 residual1,) =
            core.makerResidualTest(IOrderBookCore.Side.Ask, 105, 1);
        uint256 residualLots = uint256(residual0) + uint256(residual1);

        assertTrue(
            roundingDebt >= 0,
            "lazy maker attribution exceeded executed taker lots"
        );
        assertEq(
            uint256(roundingDebt),
            residualLots,
            "maker position + explicit residual != taker execution"
        );
        assertEq(
            takerPosition,
            int256(uint256(firstFill) + uint256(secondFill)),
            "taker position != executed lots"
        );
    }

    function testFundingRoundingResidualSettlesOnFinalRetirement() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 1);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 1);
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 1);

        core.setFundingIndex(5e17);

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            1,
            IOrderBookCore.FillPolicy.IOC
        );

        core.setFundingIndex(15e17);

        (uint128 aliceShares,,) =
            core.quotes(ALICE, IOrderBookCore.Side.Ask, 105);
        vm.prank(ALICE);
        core.removeShares(IOrderBookCore.Side.Ask, 105, aliceShares);

        (uint96 residualLots, int256 residualFundingEntry) =
            core.makerResidualTest(IOrderBookCore.Side.Ask, 105, 0);
        assertEq(uint256(residualLots), 0, "execution residual not consumed");
        assertEq(
            residualFundingEntry,
            int256(1),
            "funding rounding residual not explicit"
        );

        (uint128 bobShares,,) =
            core.quotes(BOB, IOrderBookCore.Side.Ask, 105);
        vm.prank(BOB);
        core.removeShares(IOrderBookCore.Side.Ask, 105, bobShares);

        (uint128 carolShares,,) =
            core.quotes(CAROL, IOrderBookCore.Side.Ask, 105);
        vm.prank(CAROL);
        core.removeShares(IOrderBookCore.Side.Ask, 105, carolShares);

        (residualLots, residualFundingEntry) =
            core.makerResidualTest(IOrderBookCore.Side.Ask, 105, 0);
        assertEq(uint256(residualLots), 0, "execution residual survived generation");
        assertEq(
            residualFundingEntry,
            int256(0),
            "funding residual survived generation"
        );

        (, int256 aliceTrading, int256 aliceFunding,,) =
            core.accountingStateTest(ALICE);
        (, int256 bobTrading, int256 bobFunding,,) =
            core.accountingStateTest(BOB);
        (, int256 carolTrading, int256 carolFunding,,) =
            core.accountingStateTest(CAROL);

        assertEq(
            aliceFunding + bobFunding + carolFunding,
            int256(0),
            "funding rounding residual leaked into maker claims"
        );
        assertEq(
            core.makerFundingRoundingDustTest(),
            int256(1),
            "system funding rounding dust not conserved"
        );
        assertEq(
            aliceTrading + bobTrading + carolTrading,
            int256(105),
            "maker trade cashflow not conserved"
        );
    }

    function _position(address account) internal view returns (int80 position) {
        (position,,) = core.accountRisk(account);
    }

    function _fund(address account) internal {
        token.mint(account, 10_000_000);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(10_000_000);
    }
}

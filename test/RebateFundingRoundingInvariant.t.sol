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

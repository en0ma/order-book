// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract FundingGenerationInvariantTest is TestBase {
    OrderBookCoreHarness internal core;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant MAKER0 = address(0xA0);
    address internal constant MAKER1 = address(0xA1);
    address internal constant TAKER0 = address(0xB0);
    address internal constant TAKER1 = address(0xB1);

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCoreHarness(
            address(token), address(oracle), 40, 1_000, 0, 0
        );

        _fund(MAKER0);
        _fund(MAKER1);
        _fund(TAKER0);
        _fund(TAKER1);
    }

    function testFundingConservesAcrossLazyMakerSettlement() public {
        vm.prank(MAKER0);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(TAKER0);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        core.setFundingIndex(int128(3e18));

        // Maker materializes the full short and its funding attribution lazily.
        vm.prank(MAKER0);
        core.settle(IOrderBookCore.Side.Ask, 100);

        int256 makerEquity = core.accountEquity(MAKER0);
        int256 takerEquity = core.accountEquity(TAKER0);

        // At mark == execution tick, trading PnL cancels and funding is zero-sum.
        assertEq(
            makerEquity + takerEquity,
            int256(20_000_000),
            "funding created or destroyed aggregate equity"
        );
    }

    function testShareBurnCrystallizesRoundingFillAndPreservesFundingConservation() public {
        vm.prank(MAKER0);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 1);

        vm.prank(MAKER1);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 2);

        vm.prank(TAKER0);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            1,
            IOrderBookCore.FillPolicy.IOC
        );

        core.setFundingIndex(int128(3e18));

        vm.prank(MAKER0);
        (uint128 maker0Shares,,) =
            core.quotes(MAKER0, IOrderBookCore.Side.Ask, 100);

        vm.prank(MAKER0);
        uint96 removed =
            core.removeShares(IOrderBookCore.Side.Ask, 100, maker0Shares);

        assertEq(removed, 0, "rounding-boundary burn redeemed a pool lot");

        (int80 maker0Position,,) = core.accountRisk(MAKER0);
        assertEq(int256(maker0Position), -1, "burn-exposed fill not crystallized");

        int256 pairEquity =
            core.accountEquity(MAKER0) + core.accountEquity(TAKER0);
        assertEq(
            pairEquity,
            int256(20_000_000),
            "burn-exposed fill broke maker/taker funding conservation"
        );

        (, uint96 remaining,) =
            core.pools(IOrderBookCore.Side.Ask, 100);
        assertEq(remaining, 2, "share burn changed remaining maker lots");

        vm.prank(TAKER0);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            2,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(MAKER1);
        core.settle(IOrderBookCore.Side.Ask, 100);

        (int80 maker1Position,,) = core.accountRisk(MAKER1);
        (int80 takerPosition,,) = core.accountRisk(TAKER0);

        assertEq(int256(maker1Position), -2, "neighbor maker fill attribution mismatch");
        assertEq(int256(takerPosition), 3, "taker executed position mismatch");
        assertEq(
            int256(maker0Position) + int256(maker1Position) + int256(takerPosition),
            0,
            "share burn left permanent maker attribution debt"
        );
    }

    function testPartialShareBurnSplitsHistoricalFundingFromSurvivingShares() public {
        vm.prank(MAKER0);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 2);

        vm.prank(MAKER1);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 1);

        vm.prank(TAKER0);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            1,
            IOrderBookCore.FillPolicy.IOC
        );

        core.setFundingIndex(int128(2e18));

        vm.prank(MAKER0);
        (uint128 maker0Shares,,) =
            core.quotes(MAKER0, IOrderBookCore.Side.Ask, 100);

        vm.prank(MAKER0);
        uint96 removed =
            core.removeShares(
                IOrderBookCore.Side.Ask,
                100,
                maker0Shares / 2
            );

        assertEq(removed, 0, "partial burn unexpectedly redeemed pool lots");

        (int80 maker0AfterBurn,,) = core.accountRisk(MAKER0);
        assertEq(
            int256(maker0AfterBurn),
            -1,
            "partial burn did not crystallize historical maker fill"
        );

        (,, int256 maker0FundingAfterBurn,,) =
            core.accountingStateTest(MAKER0);
        assertEq(
            maker0FundingAfterBurn,
            2,
            "burned slice funding attribution mismatch"
        );

        core.setFundingIndex(int128(5e18));

        vm.prank(TAKER0);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            2,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(MAKER0);
        core.settle(IOrderBookCore.Side.Ask, 100);
        vm.prank(MAKER1);
        core.settle(IOrderBookCore.Side.Ask, 100);

        (int80 maker0Final,,) = core.accountRisk(MAKER0);
        (int80 maker1Final,,) = core.accountRisk(MAKER1);
        (int80 takerFinal,,) = core.accountRisk(TAKER0);

        assertEq(int256(maker0Final), -2, "surviving maker shares lost later fill");
        assertEq(int256(maker1Final), -1, "neighbor maker fill mismatch");
        assertEq(int256(takerFinal), 3, "taker fill mismatch");
        assertEq(
            int256(maker0Final) + int256(maker1Final) + int256(takerFinal),
            0,
            "partial burn broke position conservation"
        );

        (,, int256 maker0FundingFinal,,) =
            core.accountingStateTest(MAKER0);
        assertEq(
            maker0FundingFinal,
            5,
            "surviving shares double-counted or lost historical funding"
        );

        int256 aggregateEquity =
            core.accountEquity(MAKER0) + core.accountEquity(MAKER1)
                + core.accountEquity(TAKER0);
        assertEq(
            aggregateEquity,
            int256(30_000_000),
            "partial burn created or destroyed aggregate value"
        );
    }

    function testClosedGenerationFundingDoesNotLeakIntoReopenedTick() public {
        vm.prank(MAKER0);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(TAKER0);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        // Generation 0 is closed but MAKER0 remains lazily unsettled.
        core.setFundingIndex(int128(2e18));

        vm.prank(MAKER1);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 50);

        core.setFundingIndex(int128(5e18));

        vm.prank(TAKER1);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            50,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(MAKER1);
        core.settle(IOrderBookCore.Side.Ask, 100);
        vm.prank(MAKER0);
        core.settle(IOrderBookCore.Side.Ask, 100);

        (int80 maker0Position,,) = core.accountRisk(MAKER0);
        (int80 maker1Position,,) = core.accountRisk(MAKER1);
        assertEq(int256(maker0Position), -100, "old generation position corrupted");
        assertEq(int256(maker1Position), -50, "new generation position corrupted");

        // Both maker/taker pairs are zero-sum at a mark equal to execution price,
        // even though the old maker settles after the new generation is consumed.
        int256 aggregate =
            core.accountEquity(MAKER0) + core.accountEquity(MAKER1)
                + core.accountEquity(TAKER0) + core.accountEquity(TAKER1);
        assertEq(
            aggregate,
            int256(40_000_000),
            "generation rollover leaked funding or trading value"
        );
    }

    function _fund(address account) internal {
        token.mint(account, 10_000_000);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(10_000_000);
    }
}

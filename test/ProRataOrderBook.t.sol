// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProRataOrderBook} from "../src/ProRataOrderBook.sol";
import {TestBase} from "./TestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract ProRataOrderBookTest is TestBase {
    ProRataOrderBook internal book;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    function setUp() public {
        book = new ProRataOrderBook();
    }

    function testBestPricePriorityAndProRataFill() public {
        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 101, 100);

        vm.prank(BOB);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 101, 300);

        vm.prank(CAROL);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 102, 500);

        uint96 filled =
            book.take(ProRataOrderBook.Side.Bid, 102, 200, ProRataOrderBook.FillPolicy.IOC);
        assertEq(filled, 200, "wrong taker fill");

        (, , uint96 aliceRemaining, uint96 aliceFill) =
            book.quoteState(ALICE, ProRataOrderBook.Side.Ask, 101);
        (, , uint96 bobRemaining, uint96 bobFill) =
            book.quoteState(BOB, ProRataOrderBook.Side.Ask, 101);

        assertEq(aliceFill, 50, "alice pro-rata fill");
        assertEq(bobFill, 150, "bob pro-rata fill");
        assertEq(aliceRemaining + bobRemaining, 200, "remaining tick liquidity");
    }

    function testLateMakerDoesNotReceiveHistoricalFill() public {
        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 100);

        book.take(ProRataOrderBook.Side.Bid, 100, 40, ProRataOrderBook.FillPolicy.IOC);

        vm.prank(BOB);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 60);

        (, , , uint96 bobHistoricalFill) =
            book.quoteState(BOB, ProRataOrderBook.Side.Ask, 100);
        assertEq(bobHistoricalFill, 0, "late maker inherited old fill");

        book.take(ProRataOrderBook.Side.Bid, 100, 60, ProRataOrderBook.FillPolicy.IOC);

        (, , , uint96 aliceFill) =
            book.quoteState(ALICE, ProRataOrderBook.Side.Ask, 100);
        (, , , uint96 bobFill) = book.quoteState(BOB, ProRataOrderBook.Side.Ask, 100);

        assertTrue(aliceFill > 40, "alice did not receive future fill");
        assertTrue(bobFill > 0, "bob missed future fill");
    }

    function testCancellationLeavesNoTombstone() public {
        vm.prank(ALICE);
        uint128 shares = book.addLiquidity(ProRataOrderBook.Side.Bid, 99, 100);

        vm.prank(ALICE);
        uint96 removed = book.removeShares(ProRataOrderBook.Side.Bid, 99, shares);
        assertEq(removed, 100, "full cancellation should redeem all lots");

        (bool ok,) = book.bestBid();
        assertTrue(!ok, "cancelled tick remained occupied");
    }

    function testFullDepletionRollsGenerationAndSettlesLater() public {
        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 100);

        book.take(ProRataOrderBook.Side.Bid, 100, 100, ProRataOrderBook.FillPolicy.FOK);

        vm.prank(ALICE);
        uint96 settled = book.settle(ProRataOrderBook.Side.Ask, 100);
        assertEq(settled, 100, "closed generation did not settle");

        (int128 position,,) = book.accountRisk(ALICE);
        assertEq(int256(position), -100, "ask fill should create short position");
    }

    function testFokDoesNotPartiallyExecute() public {
        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 40);

        vm.prank(BOB);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 101, 50);

        (bool ok,) = address(book).call(
            abi.encodeCall(
                book.take,
                (
                    ProRataOrderBook.Side.Bid,
                    uint16(101),
                    uint96(100),
                    ProRataOrderBook.FillPolicy.FOK
                )
            )
        );
        assertTrue(!ok, "FOK should fail when aggregate liquidity is insufficient");

        (, uint96 l0,) = book.pools(ProRataOrderBook.Side.Ask, 100);
        (, uint96 l1,) = book.pools(ProRataOrderBook.Side.Ask, 101);

        assertEq(l0, 40, "FOK mutated first level");
        assertEq(l1, 50, "FOK mutated second level");
    }

    function testFuzzConservation(uint256 aRaw, uint256 bRaw, uint256 fillRaw) public {
        uint96 a = boundNonZero(aRaw, 1_000_000);
        uint96 b = boundNonZero(bRaw, 1_000_000);
        uint96 total = a + b;
        uint96 fill = uint96(fillRaw % (uint256(total) + 1));

        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 500, a);
        vm.prank(BOB);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 500, b);

        if (fill != 0) {
            book.take(ProRataOrderBook.Side.Bid, 500, fill, ProRataOrderBook.FillPolicy.IOC);
        }

        (, uint96 remaining,) = book.pools(ProRataOrderBook.Side.Ask, 500);

        assertEq(
            book.totalAddedLots(),
            book.totalExecutedLots() + book.totalRemovedLots() + remaining,
            "global lot conservation"
        );
    }

    function testERC20CollateralCustodyAndWithdrawal() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        book.configureSettlement(address(token), address(oracle));
        book.configureRisk(100, 10, 1_000);

        token.mint(ALICE, 50_000);

        vm.prank(ALICE);
        token.approve(address(book), 50_000);

        vm.prank(ALICE);
        book.depositCollateral(50_000);

        assertEq(token.balanceOf(address(book)), 50_000, "book did not custody collateral");
        assertEq(book.collateralBalance(ALICE), 50_000, "internal collateral mismatch");

        vm.prank(ALICE);
        uint128 shares = book.addLiquidity(ProRataOrderBook.Side.Bid, 99, 100);

        uint256 reserved = book.reservedMargin(ALICE);
        assertTrue(reserved > 0, "margin was not reserved");

        vm.prank(ALICE);
        (bool ok,) =
            address(book).call(abi.encodeCall(book.withdrawCollateral, (1_000)));
        assertTrue(!ok, "withdraw ignored unsettled quote state");

        vm.prank(ALICE);
        book.removeShares(ProRataOrderBook.Side.Bid, 99, shares);

        assertEq(book.activeQuoteCount(ALICE), 0, "quote count did not clear");

        vm.prank(ALICE);
        book.withdrawCollateral(1_000);

        assertEq(token.balanceOf(ALICE), 1_000, "withdraw did not transfer token");
        assertEq(token.balanceOf(address(book)), 49_000, "custody balance mismatch");
    }

    function testExternalOracleDrivesExecutionBand() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        book.configureSettlement(address(token), address(oracle));
        book.configureRisk(1, 5, 1_000);

        token.mint(ALICE, 100_000);
        vm.prank(ALICE);
        token.approve(address(book), type(uint256).max);
        vm.prank(ALICE);
        book.depositCollateral(100_000);

        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 104, 100);

        oracle.setMarkTick(90);

        uint96 filled =
            book.take(ProRataOrderBook.Side.Bid, 200, 100, ProRataOrderBook.FillPolicy.IOC);
        assertEq(filled, 0, "external oracle was ignored");

        oracle.setMarkTick(100);
        filled = book.take(ProRataOrderBook.Side.Bid, 200, 100, ProRataOrderBook.FillPolicy.IOC);
        assertEq(filled, 100, "oracle-qualified quote did not execute");
    }

    function testLazyFundingAccruesFromFillIndexWithoutMakerWrite() public {
        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 100);

        book.setFundingIndex(int128(1e18));

        uint96 filled =
            book.take(ProRataOrderBook.Side.Bid, 100, 40, ProRataOrderBook.FillPolicy.IOC);
        assertEq(filled, 40, "wrong fill");

        // Funding moved after the maker fill. The taker path still did not touch maker funding.
        assertEq(book.fundingCashflow(ALICE), 0, "fill eagerly wrote maker funding");

        book.setFundingIndex(int128(2e18));

        vm.prank(ALICE);
        uint96 settled = book.settle(ProRataOrderBook.Side.Ask, 100);
        assertEq(settled, 40, "wrong lazy fill settlement");

        // A short receives +1 unit per lot when the cumulative funding index rises by 1e18.
        assertEq(book.fundingCashflow(ALICE), 40, "lazy fill funding mismatch");
    }

    function testMaterializedPositionContinuesFundingAfterQuoteSettlement() public {
        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 100);

        book.setFundingIndex(int128(1e18));
        book.take(ProRataOrderBook.Side.Bid, 100, 40, ProRataOrderBook.FillPolicy.IOC);

        book.setFundingIndex(int128(2e18));
        vm.prank(ALICE);
        book.settle(ProRataOrderBook.Side.Ask, 100);

        assertEq(book.fundingCashflow(ALICE), 40, "first funding interval mismatch");

        book.setFundingIndex(int128(3e18));
        vm.prank(ALICE);
        book.settleFunding();

        assertEq(book.fundingCashflow(ALICE), 80, "materialized position funding mismatch");
    }

    function testRiskRejectsUndercollateralizedQuote() public {
        book.configureRisk(100, 10, 1_000);

        vm.prank(ALICE);
        book.depositCollateral(500);

        vm.prank(ALICE);
        (bool ok,) = address(book).call(
            abi.encodeCall(book.addLiquidity, (ProRataOrderBook.Side.Bid, uint16(99), uint96(100)))
        );

        assertTrue(!ok, "undercollateralized quote entered the book");

        (bool hasBid,) = book.bestBid();
        assertTrue(!hasBid, "failed quote left executable liquidity");
    }

    function testExecutionBandLeavesOutOfBandQuoteRestingButUnfilled() public {
        book.configureRisk(100, 5, 1_000);

        vm.prank(ALICE);
        book.depositCollateral(100_000);

        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 104, 100);

        book.setMarkTick(90);

        uint96 filled =
            book.take(ProRataOrderBook.Side.Bid, 200, 100, ProRataOrderBook.FillPolicy.IOC);
        assertEq(filled, 0, "out-of-band quote executed");

        (, uint96 remaining,) = book.pools(ProRataOrderBook.Side.Ask, 104);
        assertEq(remaining, 100, "out-of-band quote was mutated");

        book.setMarkTick(100);
        filled = book.take(ProRataOrderBook.Side.Bid, 200, 100, ProRataOrderBook.FillPolicy.IOC);
        assertEq(filled, 100, "quote did not reactivate inside oracle band");
    }

    function testOracleRisePastPoolRiskCeilingFreezesOldLiquidity() public {
        book.configureRisk(100, 5, 1_000);

        vm.prank(ALICE);
        book.depositCollateral(100_000);

        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 104, 100);

        assertEq(book.poolRiskCeilingTick(ProRataOrderBook.Side.Ask, 104), 105, "wrong pool ceiling");

        book.setMarkTick(106);

        uint96 filled =
            book.take(ProRataOrderBook.Side.Bid, 200, 100, ProRataOrderBook.FillPolicy.IOC);
        assertEq(filled, 0, "stale risk pool executed above reserved ceiling");

        (, uint96 remaining,) = book.pools(ProRataOrderBook.Side.Ask, 104);
        assertEq(remaining, 100, "stale risk pool was mutated");
    }

    function testMakerRiskStateDoesNotChangeOnTakerFill() public {
        book.configureRisk(100, 10, 1_000);

        vm.prank(ALICE);
        book.depositCollateral(100_000);

        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Bid, 99, 100);

        uint256 collateralBefore = book.collateralBalance(ALICE);
        uint256 reservedBefore = book.reservedMargin(ALICE);
        (int128 settledBefore, int128 minBefore, int128 maxBefore) = book.accountRisk(ALICE);

        book.take(ProRataOrderBook.Side.Ask, 99, 60, ProRataOrderBook.FillPolicy.IOC);

        assertEq(book.collateralBalance(ALICE), collateralBefore, "fill wrote maker collateral");
        assertEq(book.reservedMargin(ALICE), reservedBefore, "fill wrote maker reserve");

        (int128 settledAfter, int128 minAfter, int128 maxAfter) = book.accountRisk(ALICE);
        assertEq(int256(settledAfter), int256(settledBefore), "fill materialized maker position");
        assertEq(int256(minAfter), int256(minBefore), "fill mutated min envelope");
        assertEq(int256(maxAfter), int256(maxBefore), "fill mutated max envelope");
    }

    function testSettlingFillTightensExposureEnvelope() public {
        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Bid, 99, 100);

        book.take(ProRataOrderBook.Side.Ask, 99, 60, ProRataOrderBook.FillPolicy.IOC);

        vm.prank(ALICE);
        book.settle(ProRataOrderBook.Side.Bid, 99);

        (int128 settled, int128 minPosition, int128 maxPosition) = book.accountRisk(ALICE);
        assertEq(int256(settled), 60, "settled position mismatch");
        assertEq(int256(minPosition), 60, "minimum envelope did not tighten");
        assertEq(int256(maxPosition), 100, "remaining bid envelope changed incorrectly");
    }

    function testRiskEnvelopeDoesNotMoveOnFill() public {
        vm.prank(ALICE);
        book.addLiquidity(ProRataOrderBook.Side.Bid, 99, 100);

        (, int128 minBefore, int128 maxBefore) = book.accountRisk(ALICE);
        assertEq(int256(minBefore), 0, "unexpected min bound");
        assertEq(int256(maxBefore), 100, "unexpected max bound");

        book.take(ProRataOrderBook.Side.Ask, 99, 60, ProRataOrderBook.FillPolicy.IOC);

        (, int128 minAfter, int128 maxAfter) = book.accountRisk(ALICE);
        assertEq(int256(minAfter), 0, "fill mutated min envelope");
        assertEq(int256(maxAfter), 100, "fill mutated max envelope");

        vm.prank(ALICE);
        book.settle(ProRataOrderBook.Side.Bid, 99);

        (int128 settled,, int128 maxSettled) = book.accountRisk(ALICE);
        assertEq(int256(settled), 60, "settled position");
        assertEq(int256(maxSettled), 100, "reachable max should remain reserved");
    }
}

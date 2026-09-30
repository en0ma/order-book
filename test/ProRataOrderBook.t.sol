// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProRataOrderBook} from "../src/ProRataOrderBook.sol";
import {TestBase} from "./TestBase.sol";

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

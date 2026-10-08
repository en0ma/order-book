// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProRataOrderBook} from "../src/ProRataOrderBook.sol";
import {TestBase} from "./TestBase.sol";

/// @notice Reproducible workload matrix for architecture comparisons.
/// @dev These numbers measure this implementation only; they are NOT Boros benchmarks.
contract BorosParityWorkloadsTest is TestBase {
    event WorkloadGas(
        string scenario, uint256 makers, uint256 ticks, uint256 filledLots, uint256 gasUsed
    );

    function _seed(ProRataOrderBook book, uint256 makers, uint16 firstTick, uint256 ticks)
        internal
    {
        for (uint256 level; level < ticks; ++level) {
            for (uint256 i; i < makers; ++i) {
                // Distinct makers, but each level has equal executable liquidity.
                vm.prank(address(uint160(0x10000 + level * 1_000 + i)));
                book.addLiquidity(
                    ProRataOrderBook.Side.Ask, firstTick + uint16(level), 100
                );
            }
        }
    }

    function _measure(uint256 makers, uint256 ticks)
        internal
        returns (uint256 gasUsed)
    {
        ProRataOrderBook book = new ProRataOrderBook();
        _seed(book, makers, 10_000, ticks);
        uint96 lots = uint96(makers * ticks * 50);
        uint256 beforeGas = gasleft();
        uint96 filled = book.take(
            ProRataOrderBook.Side.Bid, uint16(9_999 + ticks), lots,
            ProRataOrderBook.FillPolicy.IOC
        );
        gasUsed = beforeGas - gasleft();
        assertEq(filled, lots, "workload must fill at the intended price levels");
        assertEq(book.totalExecutedLots(), lots, "all fills must be recorded");
        emit WorkloadGas("take", makers, ticks, filled, gasUsed);
    }

    function testGas_BorosComparisonMakerCountMatrix() public {
        // Same aggregate quantity (6_400 lots), same tick, same taker fill (3_200).
        uint256[4] memory makers = [uint256(1), 8, 32, 64];
        uint256[4] memory gasUsed;
        for (uint256 k; k < makers.length; ++k) {
            ProRataOrderBook book = new ProRataOrderBook();
            uint96 perMaker = uint96(6_400 / makers[k]);
            for (uint256 i; i < makers[k]; ++i) {
                vm.prank(address(uint160(0x10000 + i)));
                book.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, perMaker);
            }
            uint256 beforeGas = gasleft();
            uint96 filled = book.take(
                ProRataOrderBook.Side.Bid, 10_000, 3_200,
                ProRataOrderBook.FillPolicy.IOC
            );
            gasUsed[k] = beforeGas - gasleft();
            assertEq(filled, 3_200, "fill changed with maker count");
            emit WorkloadGas("equal-depth-one-tick", makers[k], 1, filled, gasUsed[k]);
        }
        for (uint256 k = 1; k < makers.length; ++k) {
            uint256 diff = gasUsed[k] > gasUsed[0]
                ? gasUsed[k] - gasUsed[0] : gasUsed[0] - gasUsed[k];
            assertTrue(diff < 20_000, "taker gas should not scale with maker count");
        }
    }

    function testGas_BorosComparisonCrossedTickMatrix() public {
        // Fixed 8 makers per tick; crossing more levels must remain explicitly measured.
        _measure(8, 1);
        _measure(8, 2);
        _measure(8, 4);
        _measure(8, 8);
    }

    function testMakerPartialFillCancellationSettlesAndPreservesRemainingLiquidity() public {
        ProRataOrderBook book = new ProRataOrderBook();
        address[3] memory maker = [address(0xA), address(0xB), address(0xC)];
        uint128[3] memory shares;
        for (uint256 i; i < 3; ++i) {
            vm.prank(maker[i]);
            shares[i] = book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 100);
        }
        assertEq(
            book.take(ProRataOrderBook.Side.Bid, 100, 90, ProRataOrderBook.FillPolicy.IOC),
            90, "unexpected first partial fill"
        );
        for (uint256 i; i < 3; ++i) {
            (, , uint96 unfilled, uint96 pending) =
                book.quoteState(maker[i], ProRataOrderBook.Side.Ask, 100);
            assertEq(unfilled, 70, "maker remaining claim should be proportional");
            assertEq(pending, 30, "maker fill attribution should be proportional");
        }
        vm.prank(maker[0]);
        assertEq(
            book.removeShares(ProRataOrderBook.Side.Ask, 100, shares[0]),
            70, "cancellation must redeem only the unfilled claim"
        );
        assertEq(book.totalExecutedLots(), 90, "cancellation changed executed lots");
        assertEq(book.totalRemovedLots(), 70, "cancelled unfilled lots mismatch");
        (, uint96 remaining, ) = book.pools(ProRataOrderBook.Side.Ask, 100);
        assertEq(remaining, 140, "other makers' liquidity must remain");
        (, , uint96 cancelledClaim, uint96 cancelledPending) =
            book.quoteState(maker[0], ProRataOrderBook.Side.Ask, 100);
        assertEq(cancelledClaim, 0, "cancelled maker retained liquidity");
        assertEq(cancelledPending, 0, "cancelled maker retained pending fill");
        assertEq(
            book.take(ProRataOrderBook.Side.Bid, 100, 140, ProRataOrderBook.FillPolicy.FOK),
            140, "remaining makers must still be executable"
        );
        assertEq(book.totalExecutedLots(), 230, "total executed amount mismatch");
        assertEq(book.totalAddedLots(), book.totalExecutedLots() + book.totalRemovedLots(),
            "global conservation across fills and cancellation");
        for (uint256 i = 1; i < 3; ++i) {
            vm.prank(maker[i]);
            assertEq(book.settle(ProRataOrderBook.Side.Ask, 100), 100,
                "remaining maker must settle full position after depletion");
        }
    }

    function testFuzz_PartialFillCancellationConservesLots(
        uint64 firstRaw, uint64 secondRaw, uint64 fillRaw
    ) public {
        uint96 first = uint96(uint256(firstRaw) % 10_000 + 1);
        uint96 second = uint96(uint256(secondRaw) % 10_000 + 1);
        uint96 amount = uint96(uint256(fillRaw) % (uint256(first) + second + 1));
        ProRataOrderBook book = new ProRataOrderBook();
        vm.prank(address(0xA));
        uint128 shares = book.addLiquidity(ProRataOrderBook.Side.Ask, 100, first);
        vm.prank(address(0xB));
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, second);
        if (amount != 0) {
            book.take(ProRataOrderBook.Side.Bid, 100, amount, ProRataOrderBook.FillPolicy.IOC);
        }
        (, , uint96 redeemable, ) =
            book.quoteState(address(0xA), ProRataOrderBook.Side.Ask, 100);
        if (redeemable != 0) {
            vm.prank(address(0xA));
            uint96 removed = book.removeShares(ProRataOrderBook.Side.Ask, 100, shares);
            assertEq(removed, redeemable, "cancellation must match quoted entitlement");
        }
        (, uint96 remaining, ) = book.pools(ProRataOrderBook.Side.Ask, 100);
        assertEq(
            book.totalAddedLots(), book.totalExecutedLots() + book.totalRemovedLots() + remaining,
            "filled + removed + executable must equal deposited lots"
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {TestBase} from "./TestBase.sol";

contract SegmentTreeExtremaOracleTest is TestBase {
    SegmentTreeExtremaOracle internal oracle;

    function setUp() public {
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
    }

    function testRangeExtremaAcrossUpdates() public {
        uint64 start = oracle.currentObservationId();

        oracle.record(120);
        oracle.record(90);
        oracle.record(115);
        oracle.record(95);

        (uint16 high, uint16 low) = oracle.highLowSince(start);
        assertEq(high, 120, "wrong range high");
        assertEq(low, 90, "wrong range low");
        assertEq(oracle.markTick(), 95, "wrong current mark");
    }

    function testSubrangeExtrema() public {
        oracle.record(130);
        uint64 start = oracle.currentObservationId();
        oracle.record(125);
        oracle.record(110);
        oracle.record(118);

        (uint16 high, uint16 low) = oracle.highLowSince(start);
        assertEq(high, 130, "subrange high");
        assertEq(low, 110, "subrange low");
    }

    function testTickZeroIsNotTreatedAsEmptyNode() public {
        uint64 start = oracle.currentObservationId();

        oracle.record(0);
        oracle.record(25);

        (uint16 high, uint16 low) = oracle.highLowSince(start);
        assertEq(high, 100, "zero-range high");
        assertEq(low, 0, "tick zero lost as empty sentinel");
    }

    function testStaleObservationBlocksMarkAndExtremaUntilRefresh() public {
        SegmentTreeExtremaOracle staleOracle =
            new SegmentTreeExtremaOracle(address(this), 100, 60);
        uint64 start = staleOracle.currentObservationId();

        vm.warp(block.timestamp + 61);

        (bool markOk,) =
            address(staleOracle).call(abi.encodeCall(staleOracle.markTick, ()));
        assertTrue(!markOk, "stale mark remained readable");

        (bool extremaOk,) = address(staleOracle).call(
            abi.encodeCall(staleOracle.highLowSince, (start))
        );
        assertTrue(!extremaOk, "stale extrema remained readable");

        staleOracle.record(101);
        assertEq(staleOracle.markTick(), 101, "fresh record did not restore oracle");

        (uint16 high, uint16 low) = staleOracle.highLowSince(start);
        assertEq(high, 101, "fresh extrema high");
        assertEq(low, 100, "fresh extrema low");
    }

    function testUnauthorizedRecorderRejected() public {
        vm.prank(address(0xBEEF));
        (bool ok,) =
            address(oracle).call(abi.encodeCall(oracle.record, (uint16(101))));
        assertTrue(!ok, "unauthorized recorder accepted");
    }

    function testUpdaterRotationRequiresTwoStepAcceptance() public {
        address nextUpdater = address(0xBEEF);

        oracle.proposeUpdater(nextUpdater);
        assertTrue(oracle.pendingUpdater() == nextUpdater, "pending updater mismatch");

        (bool ownerAcceptOk,) =
            address(oracle).call(abi.encodeCall(oracle.acceptUpdater, ()));
        assertTrue(!ownerAcceptOk, "owner accepted updater on behalf of nominee");

        vm.prank(nextUpdater);
        oracle.acceptUpdater();

        assertTrue(oracle.updater() == nextUpdater, "updater not transferred");
        assertTrue(oracle.pendingUpdater() == address(0), "pending updater not cleared");

        (bool oldUpdaterOk,) =
            address(oracle).call(abi.encodeCall(oracle.record, (uint16(101))));
        assertTrue(!oldUpdaterOk, "old updater retained publish authority");

        vm.prank(nextUpdater);
        oracle.record(101);
        assertEq(oracle.markTick(), 101, "new updater could not publish");
    }

    function testUpdaterTransferCanBeCancelled() public {
        address nextUpdater = address(0xCAFE);

        oracle.proposeUpdater(nextUpdater);
        oracle.cancelUpdaterTransfer();

        assertTrue(oracle.pendingUpdater() == address(0), "pending updater not cancelled");

        vm.prank(nextUpdater);
        (bool ok,) =
            address(oracle).call(abi.encodeCall(oracle.acceptUpdater, ()));
        assertTrue(!ok, "cancelled updater accepted authority");
        assertTrue(oracle.updater() == address(this), "updater changed after cancellation");
    }

    function testUnauthorizedAccountCannotProposeUpdater() public {
        vm.prank(address(0xBEEF));
        (bool ok,) = address(oracle).call(
            abi.encodeCall(oracle.proposeUpdater, (address(0xCAFE)))
        );
        assertTrue(!ok, "unauthorized updater proposal accepted");
    }

    function testObservationExpiresAfterRingWindow() public {
        uint64 first = oracle.currentObservationId();

        for (uint256 i; i < oracle.CAPACITY(); ++i) {
            oracle.record(uint16(100 + (i % 50)));
        }

        (bool ok,) =
            address(oracle).call(abi.encodeCall(oracle.highLowSince, (first)));
        assertTrue(!ok, "expired observation remained queryable");
    }
}

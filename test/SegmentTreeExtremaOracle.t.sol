// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {TestBase} from "./TestBase.sol";

contract SegmentTreeExtremaOracleTest is TestBase {
    SegmentTreeExtremaOracle internal oracle;

    function setUp() public {
        oracle = new SegmentTreeExtremaOracle(address(this), 100);
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

    function testUnauthorizedRecorderRejected() public {
        vm.prank(address(0xBEEF));
        (bool ok,) =
            address(oracle).call(abi.encodeCall(oracle.record, (uint16(101))));
        assertTrue(!ok, "unauthorized recorder accepted");
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

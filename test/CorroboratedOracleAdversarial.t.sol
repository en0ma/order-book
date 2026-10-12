// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {CorroboratedPriceSource} from "../src/CorroboratedPriceSource.sol";
import {MockExternalPriceSource} from "./mocks/MockExternalPriceSource.sol";

/// @notice Adversarial observations against the two-source mark corroboration boundary.
contract CorroboratedOracleAdversarialTest is TestBase {
    MockExternalPriceSource internal primary;
    MockExternalPriceSource internal referenceSource;
    CorroboratedPriceSource internal gate;

    function setUp() public {
        vm.warp(1_000);
        primary = new MockExternalPriceSource(100e8, 250_000, 1_000);
        referenceSource = new MockExternalPriceSource(100e18, 0, 1_000);
        gate = new CorroboratedPriceSource(
            address(primary), address(referenceSource), 1e8, 1e18, 60, 100
        );
    }

    function _assertRejected(bytes4 expectedSelector) internal {
        (bool ok, bytes memory reason) =
            address(gate).call(abi.encodeCall(gate.latestPrice, ()));
        assertTrue(!ok, "adversarial observation accepted");
        assertTrue(
            reason.length >= 4 && bytes4(reason) == expectedSelector,
            "unexpected rejection reason"
        );
    }

    function testDifferentDecimalsPreservePrimaryPriceAndTimestamp() public {
        (int256 price, uint256 confidence, uint48 time) = gate.latestPrice();
        assertEq(price, int256(100e8), "primary price changed");
        assertEq(confidence, 250_000, "primary confidence changed");
        assertEq(uint256(time), 1_000, "source timestamp changed");
    }

    function testRejectsReferenceDeviationJustOutsideBoundary() public {
        referenceSource.set(101_0001e14, 0, 1_000);
        _assertRejected(CorroboratedPriceSource.SourceDeviation.selector);
    }

    function testAcceptsDeviationAtExactConfiguredBoundary() public {
        referenceSource.set(101e18, 0, 1_000);
        (int256 price,,) = gate.latestPrice();
        assertEq(price, int256(100e8), "boundary rejected");
    }

    function testRejectsStaleReferenceDespiteFreshPrimary() public {
        referenceSource.set(100e18, 0, 939);
        _assertRejected(CorroboratedPriceSource.SourceStale.selector);
    }

    function testRejectsFuturePrimaryTimestamp() public {
        primary.set(100e8, 0, 1_001);
        _assertRejected(CorroboratedPriceSource.InvalidSourceObservation.selector);
    }

    function testRejectsZeroTimestampFromEitherSource() public {
        referenceSource.set(100e18, 0, 0);
        _assertRejected(CorroboratedPriceSource.InvalidSourceObservation.selector);
    }

    function testRejectsInvalidReferencePrice() public {
        referenceSource.set(0, 0, 1_000);
        _assertRejected(CorroboratedPriceSource.InvalidSourceObservation.selector);
    }

    function testExtremePriceArithmeticFailsClosed() public {
        primary.set(type(int256).max, 0, 1_000);
        (bool ok,) = address(gate).call(abi.encodeCall(gate.latestPrice, ()));
        assertTrue(!ok, "extreme arithmetic silently accepted");
    }
}

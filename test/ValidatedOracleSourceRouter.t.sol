// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ValidatedOracleSourceRouter} from "../src/ValidatedOracleSourceRouter.sol";
import {ValidatedMarkOracleAdapter} from "../src/ValidatedMarkOracleAdapter.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockExternalPriceSource} from "./mocks/MockExternalPriceSource.sol";

contract RevertingOracleSource {
    function latestPrice() external pure returns (int256, uint256, uint48) {
        revert("source down");
    }
}

contract ValidatedOracleSourceRouterTest is TestBase {
    MockExternalPriceSource primary;
    MockExternalPriceSource backup;
    ValidatedOracleSourceRouter router;
    ValidatedMarkOracleAdapter adapter;
    SegmentTreeExtremaOracle sink;
    address constant OUTSIDER = address(0xBAD);

    function setUp() public {
        primary = new MockExternalPriceSource(100_00000000, 0, uint48(block.timestamp));
        backup = new MockExternalPriceSource(101_00000000, 0, uint48(block.timestamp));
        router = new ValidatedOracleSourceRouter(address(primary), address(backup), 60, 100);
        sink = new SegmentTreeExtremaOracle(address(this), 10_000, 120);
        adapter = new ValidatedMarkOracleAdapter(address(router), address(sink), 1e8, 100, 60, 100);
        sink.proposeUpdater(address(adapter));
        adapter.acceptSinkUpdater();
    }

    function testHealthyPrimaryCannotBeReplaced() public {
        vm.prank(OUTSIDER);
        (bool outsider,) = address(router).call(abi.encodeCall(router.activateBackup, ()));
        assertTrue(!outsider, "untrusted failover accepted");
        (bool healthy,) = address(router).call(abi.encodeCall(router.activateBackup, ()));
        assertTrue(!healthy, "healthy primary was replaced");
        assertTrue(!router.usingBackup(), "primary selection changed");
        adapter.publish();
        assertEq(sink.markTick(), 10_000, "wrong primary tick");
    }

    function testStalePrimaryUsesOnlyHealthyBackupAndPreservesSourceTime() public {
        adapter.publish();
        uint64 beforeId = sink.currentObservationId();
        vm.warp(block.timestamp + 61);
        backup.set(102_00000000, 0, uint48(block.timestamp));
        (bool stale,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!stale, "stale primary publication succeeded");
        router.activateBackup();
        assertTrue(router.usingBackup(), "backup not selected");
        adapter.publish();
        assertEq(sink.markTick(), 10_200, "backup price not used");
        assertEq(uint256(sink.currentObservationId()), uint256(beforeId + 1), "missing recovery observation");
        assertEq(uint256(sink.lastObservationTime()), block.timestamp, "source timestamp changed");

        vm.prank(OUTSIDER);
        (bool outsider,) = address(router).call(abi.encodeCall(router.restorePrimary, ()));
        assertTrue(!outsider, "untrusted restoration succeeded");
        (bool staleRestore,) = address(router).call(abi.encodeCall(router.restorePrimary, ()));
        assertTrue(!staleRestore, "stale primary restored");
        vm.warp(block.timestamp + 1);
        primary.set(103_00000000, 0, uint48(block.timestamp));
        router.restorePrimary();
        adapter.publish();
        assertEq(sink.markTick(), 10_300, "restored primary not published");
        assertTrue(!router.usingBackup(), "backup persisted after restoration");
    }

    function testRejectsUnhealthyBackupWithoutChangingPublishedOracle() public {
        adapter.publish();
        uint64 beforeId = sink.currentObservationId();
        vm.warp(block.timestamp + 61);
        backup.set(0, 0, uint48(block.timestamp));
        (bool failed,) = address(router).call(abi.encodeCall(router.activateBackup, ()));
        assertTrue(!failed, "zero backup was selected");
        assertTrue(!router.usingBackup(), "failed selection changed active source");
        assertEq(uint256(sink.currentObservationId()), uint256(beforeId), "failed failover published");
        backup.set(101_00000000, 2_00000000, uint48(block.timestamp));
        (failed,) = address(router).call(abi.encodeCall(router.activateBackup, ()));
        assertTrue(!failed, "wide-confidence backup was selected");
        backup.set(101_00000000, 0, uint48(block.timestamp + 1));
        (failed,) = address(router).call(abi.encodeCall(router.activateBackup, ()));
        assertTrue(!failed, "future backup observation selected");
    }

    function testSourceSwitchDoesNotPermitReplayOfOldBackupTimestamp() public {
        adapter.publish();
        vm.warp(block.timestamp + 1);
        // A primary outage can occur before staleness; an older healthy backup
        // must not replay the previous canonical observation.
        primary.set(0, 0, uint48(block.timestamp));
        router.activateBackup();
        uint64 beforeId = sink.currentObservationId();
        (bool replay,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!replay, "old backup observation replayed");
        assertEq(uint256(sink.currentObservationId()), uint256(beforeId), "replay mutated history");
        backup.set(101_00000000, 0, uint48(block.timestamp));
        adapter.publish();
        assertEq(sink.markTick(), 10_100, "fresh backup failed");
    }

    function testConstructorRejectsDuplicateSources() public {
        (bool ok,) = address(this).call(
            abi.encodeCall(this.deployDuplicate, ())
        );
        assertTrue(!ok, "duplicate source configured");
    }

    function deployDuplicate() external {
        new ValidatedOracleSourceRouter(address(primary), address(primary), 60, 100);
    }

    function testRevertingPrimaryAllowsExplicitRecovery() public {
        RevertingOracleSource reverting = new RevertingOracleSource();
        ValidatedOracleSourceRouter fallbackRouter =
            new ValidatedOracleSourceRouter(address(reverting), address(backup), 60, 100);
        assertTrue(!fallbackRouter.primaryHealthy(), "reverting primary marked healthy");
        fallbackRouter.activateBackup();
        assertTrue(fallbackRouter.usingBackup(), "reverting feed could not fail over");
    }
}

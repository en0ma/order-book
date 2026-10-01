// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ValidatedMarkOracleAdapter} from "../src/ValidatedMarkOracleAdapter.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockExternalPriceSource} from "./mocks/MockExternalPriceSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract ValidatedMarkOracleAdapterTest is TestBase {
    MockExternalPriceSource internal source;
    SegmentTreeExtremaOracle internal oracle;
    ValidatedMarkOracleAdapter internal adapter;

    function setUp() public {
        source = new MockExternalPriceSource(
            100_25000000,
            10_000000,
            uint48(block.timestamp)
        );

        oracle = new SegmentTreeExtremaOracle(address(this), 10_000, 3_600);
        adapter = new ValidatedMarkOracleAdapter(
            address(source),
            address(oracle),
            1e8,
            100,
            60,
            100
        );

        oracle.proposeUpdater(address(adapter));
        vm.prank(address(adapter));
        oracle.acceptUpdater();
    }

    function testNormalizesAndPublishesSourcePriceIntoCanonicalTicks() public {
        uint64 beforeId = oracle.currentObservationId();
        uint64 id = adapter.publish();

        assertEq(uint256(id), uint256(beforeId + 1), "observation not appended");
        assertEq(oracle.markTick(), 10_025, "normalized tick mismatch");
    }

    function testRejectsDuplicateSourceObservationReplay() public {
        uint48 sourceTime = 10;
        vm.warp(sourceTime);
        source.set(100_25000000, 10_000000, sourceTime);
        adapter.publish();

        uint64 beforeId = oracle.currentObservationId();
        uint48 beforeRelayTime = oracle.lastObservationTime();

        vm.warp(40);
        source.set(101_00000000, 0, sourceTime);

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!ok, "duplicate source time refreshed canonical oracle");
        assertEq(
            uint256(oracle.currentObservationId()),
            uint256(beforeId),
            "duplicate replay appended observation"
        );
        assertEq(
            uint256(oracle.lastObservationTime()),
            uint256(beforeRelayTime),
            "duplicate replay refreshed canonical timestamp"
        );
    }

    function testRejectsOlderSourceObservationEvenIfStillFresh() public {
        vm.warp(block.timestamp + 10);
        source.set(100_00000000, 0, uint48(block.timestamp));
        adapter.publish();

        source.set(101_00000000, 0, uint48(block.timestamp - 1));

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!ok, "older source observation accepted");
        assertEq(oracle.markTick(), 10_000, "older source observation changed mark");
    }

    function testAcceptsStrictlyNewerSourceObservation() public {
        adapter.publish();

        vm.warp(block.timestamp + 1);
        source.set(101_00000000, 0, uint48(block.timestamp));
        uint64 nextId = adapter.publish();

        assertEq(oracle.markTick(), 10_100, "newer source observation rejected");
        assertEq(
            uint256(adapter.lastSourcePublishTime()),
            block.timestamp,
            "source publish time checkpoint not advanced"
        );
        assertEq(
            uint256(nextId),
            uint256(oracle.currentObservationId()),
            "newer observation id mismatch"
        );
    }

    function testNearExpirySourceDoesNotReceiveFreshRelayWindow() public {
        vm.warp(block.timestamp + 59);
        uint48 sourceTime = uint48(block.timestamp - 59);
        source.set(100_00000000, 0, sourceTime);

        adapter.publish();

        assertEq(
            uint256(oracle.lastObservationTime()),
            uint256(sourceTime),
            "canonical oracle replaced source time with relay time"
        );

        vm.warp(uint256(sourceTime) + 60);
        assertEq(
            oracle.markTick(),
            10_000,
            "canonical oracle expired before its configured stale window"
        );

        vm.warp(uint256(sourceTime) + 3_601);
        (bool ok,) = address(oracle).call(abi.encodeCall(oracle.markTick, ()));
        assertTrue(!ok, "canonical oracle ignored preserved source timestamp");
    }

    function testRejectsStalePrice() public {
        vm.warp(block.timestamp + 61);

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!ok, "stale external price accepted");
        assertEq(oracle.markTick(), 10_000, "stale price changed canonical mark");
    }

    function testRejectsFuturePrice() public {
        source.set(100_00000000, 0, uint48(block.timestamp + 1));

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!ok, "future external price accepted");
    }

    function testRejectsNonPositivePrice() public {
        source.set(0, 0, uint48(block.timestamp));

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!ok, "non-positive price accepted");
    }

    function testRejectsWideConfidence() public {
        source.set(100_00000000, 2_00000000, uint48(block.timestamp));

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!ok, "wide confidence accepted");
    }

    function testAcceptsConfidenceAtConfiguredBoundary() public {
        source.set(100_00000000, 1_00000000, uint48(block.timestamp));
        adapter.publish();
        assertEq(oracle.markTick(), 10_000, "confidence boundary rejected");
    }

    function testRejectsNormalizedTickOverflow() public {
        source.set(700_00000000, 0, uint48(block.timestamp));

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!ok, "tick overflow accepted");
    }

    function testPermissionlessRelayCannotBypassValidation() public {
        address relayer = address(0xCAFE);
        source.set(100_50000000, 0, uint48(block.timestamp));

        vm.prank(relayer);
        adapter.publish();

        assertEq(oracle.markTick(), 10_050, "permissionless relay failed");

        source.set(100_50000000, 2_00000000, uint48(block.timestamp));
        vm.prank(relayer);
        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.publish, ()));
        assertTrue(!ok, "relayer bypassed confidence validation");
    }

    function testCoreAndAdvancedOrdersShareCanonicalAdapterFedOracle() public {
        MockERC20 token = new MockERC20();
        source.set(100_00000000, 0, uint48(block.timestamp));
        adapter.publish();

        OrderBookCore core =
            new OrderBookCore(address(token), address(oracle), 20, 1_000, 0, 0);
        AdvancedOrderModule advanced =
            new AdvancedOrderModule(address(core), address(oracle));

        core.configureAdvancedModule(address(advanced));

        assertTrue(
            address(core.markOracle()) == address(oracle),
            "core not using canonical extrema oracle"
        );

        address maker = address(0xB0B);
        address taker = address(0xA11CE);

        token.mint(maker, 100_000);
        token.mint(taker, 100_000);

        vm.prank(maker);
        token.approve(address(core), type(uint256).max);
        vm.prank(maker);
        core.depositCollateral(100_000);

        vm.prank(taker);
        token.approve(address(core), type(uint256).max);
        vm.prank(taker);
        core.depositCollateral(100_000);

        vm.prank(maker);
        core.addLiquidity(IOrderBookCore.Side.Ask, 10_000, 10);

        vm.prank(taker);
        uint96 filled =
            core.take(IOrderBookCore.Side.Bid, 10_000, 10, IOrderBookCore.FillPolicy.IOC);
        assertEq(filled, 10, "adapter-fed matching failed");

        uint64 start = oracle.currentObservationId();
        vm.warp(block.timestamp + 1);
        source.set(101_00000000, 0, uint48(block.timestamp));
        adapter.publish();
        (uint16 high, uint16 low) = oracle.highLowSince(start);

        assertEq(high, 10_100, "trailing history high mismatch");
        assertEq(low, 10_000, "trailing history low mismatch");
    }
}

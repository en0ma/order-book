// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ValidatedMarkOracleAdapter} from "../src/ValidatedMarkOracleAdapter.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockExternalPriceSource} from "./mocks/MockExternalPriceSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract ValidatedMarkOracleAdapterTest is TestBase {
    MockExternalPriceSource internal source;
    ValidatedMarkOracleAdapter internal adapter;

    function setUp() public {
        source = new MockExternalPriceSource(
            100_25000000,
            10_000000,
            uint48(block.timestamp)
        );
        adapter = new ValidatedMarkOracleAdapter(
            address(source),
            1e8,
            100,
            60,
            100
        );
    }

    function testNormalizesSourcePriceIntoProtocolTicks() public {
        assertEq(adapter.markTick(), 10_025, "normalized tick mismatch");
    }

    function testRejectsStalePrice() public {
        vm.warp(block.timestamp + 61);

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.markTick, ()));
        assertTrue(!ok, "stale external price accepted");
    }

    function testRejectsFuturePrice() public {
        source.set(100_00000000, 0, uint48(block.timestamp + 1));

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.markTick, ()));
        assertTrue(!ok, "future external price accepted");
    }

    function testRejectsNonPositivePrice() public {
        source.set(0, 0, uint48(block.timestamp));

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.markTick, ()));
        assertTrue(!ok, "non-positive price accepted");
    }

    function testRejectsWideConfidence() public {
        // Price 100 with confidence 2 = 2%, above configured 1%.
        source.set(100_00000000, 2_00000000, uint48(block.timestamp));

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.markTick, ()));
        assertTrue(!ok, "wide confidence accepted");
    }

    function testAcceptsConfidenceAtConfiguredBoundary() public {
        // Price 100 with confidence 1 = exactly 1%.
        source.set(100_00000000, 1_00000000, uint48(block.timestamp));
        assertEq(adapter.markTick(), 10_000, "confidence boundary rejected");
    }

    function testRejectsNormalizedTickOverflow() public {
        source.set(700_00000000, 0, uint48(block.timestamp));

        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.markTick, ()));
        assertTrue(!ok, "tick overflow accepted");
    }

    function testDeployableCoreConsumesValidatedAdapterWithoutVendorCoupling() public {
        MockERC20 token = new MockERC20();
        source.set(100_00000000, 0, uint48(block.timestamp));

        OrderBookCore core =
            new OrderBookCore(address(token), address(adapter), 20, 1_000, 0, 0);

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
        assertEq(filled, 10, "adapter-backed matching failed");

        source.set(100_00000000, 2_00000000, uint48(block.timestamp));

        vm.prank(maker);
        (bool ok,) = address(core).call(
            abi.encodeCall(
                core.addLiquidity,
                (IOrderBookCore.Side.Ask, uint16(10_001), uint96(1))
            )
        );
        assertTrue(!ok, "core accepted invalid-confidence mark");
    }
}

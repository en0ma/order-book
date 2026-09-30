// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProRataOrderBook} from "../src/ProRataOrderBook.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract ExtremaOracleIntegrationTest is TestBase {
    function testSegmentTreeOracleExecutesTrailingStop() public {
        ProRataOrderBook book = new ProRataOrderBook();
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);

        address account = address(0xA11CE);
        address maker = address(0xB0B);
        address exitMaker = address(0xCAFE);

        book.configureSettlement(address(token), address(oracle));
        book.configureExtremaOracle(address(oracle));
        book.configureRisk(100, 40, 1_000);

        token.mint(account, 100_000);
        token.mint(maker, 100_000);
        token.mint(exitMaker, 100_000);

        vm.prank(account);
        token.approve(address(book), type(uint256).max);
        vm.prank(account);
        book.depositCollateral(100_000);

        vm.prank(maker);
        token.approve(address(book), type(uint256).max);
        vm.prank(maker);
        book.depositCollateral(100_000);

        vm.prank(exitMaker);
        token.approve(address(book), type(uint256).max);
        vm.prank(exitMaker);
        book.depositCollateral(100_000);

        vm.prank(maker);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 80);

        vm.prank(account);
        book.take(ProRataOrderBook.Side.Bid, 100, 80, ProRataOrderBook.FillPolicy.IOC);

        vm.prank(account);
        uint64 trailingId = book.placeTrailingOrder(
            ProRataOrderBook.Side.Ask,
            10,
            80,
            80,
            ProRataOrderBook.FillPolicy.IOC,
            true
        );

        oracle.record(125);
        oracle.record(118);

        vm.prank(exitMaker);
        book.addLiquidity(ProRataOrderBook.Side.Bid, 114, 80);

        oracle.record(114);

        uint96 filled = book.executeTrailingOrder(trailingId);
        assertEq(filled, 80, "segment-tree trailing execution mismatch");

        (int80 settled,,) = book.accountRisk(account);
        assertEq(int256(settled), 0, "segment-tree trailing did not close position");
    }

    function testStaleOracleFailsClosedForDeployableMatchingUntilFreshUpdate() public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 100, 60);
        OrderBookCore core =
            new OrderBookCore(address(token), address(oracle), 20, 1_000, 0, 0);

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
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.warp(block.timestamp + 61);

        vm.prank(taker);
        (bool staleTakeOk,) = address(core).call(
            abi.encodeCall(
                core.take,
                (
                    IOrderBookCore.Side.Bid,
                    uint16(100),
                    uint96(10),
                    IOrderBookCore.FillPolicy.IOC
                )
            )
        );
        assertTrue(!staleTakeOk, "stale oracle allowed matching");

        oracle.record(100);

        vm.prank(taker);
        uint96 filled =
            core.take(IOrderBookCore.Side.Bid, 100, 10, IOrderBookCore.FillPolicy.IOC);
        assertEq(filled, 10, "fresh oracle did not restore matching");
    }

    function testSegmentTreeQueryCostIsBoundedByTreeHeight() public {
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        uint64 start = oracle.currentObservationId();

        for (uint256 i; i < 64; ++i) {
            oracle.record(uint16(90 + (i % 30)));
        }

        uint256 g0 = gasleft();
        (uint16 high, uint16 low) = oracle.highLowSince(start);
        uint256 used = g0 - gasleft();

        assertTrue(high >= low, "invalid extrema");
        assertTrue(used < 120_000, "extrema query gas ceiling exceeded");
    }
}

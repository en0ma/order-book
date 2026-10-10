// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChainlinkPriceSource, IChainlinkAggregatorV3} from "../src/ChainlinkPriceSource.sol";
import {ValidatedMarkOracleAdapter} from "../src/ValidatedMarkOracleAdapter.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {TestBase} from "./TestBase.sol";

/// @notice Runs against the actual Ethereum Chainlink ETH/USD proxy, not a mock feed.
contract ChainlinkPriceSourceMainnetForkTest is TestBase {
    address internal constant ETH_USD =
        0x5f4eC3Df9CBD43714FE2740f5E3616155C5b8419;

    function testLiveChainlinkFeedPublishesToCanonicalOracle() public {
        vm.createSelectFork(vm.envString("ETH_RPC"));
        assertEq(block.chainid, 1, "expected Ethereum mainnet");
        assertTrue(ETH_USD.code.length > 0, "Chainlink feed missing");

        ChainlinkPriceSource source =
            new ChainlinkPriceSource(ETH_USD, address(0), 3 days, 0);
        assertEq(
            source.sourceScale(),
            10 ** uint256(IChainlinkAggregatorV3(ETH_USD).decimals()),
            "incorrect Chainlink decimal scale"
        );
        (int256 price, uint256 confidence, uint48 sourceTime) = source.latestPrice();
        assertTrue(price > 0, "invalid live Chainlink price");
        assertEq(confidence, 0, "AggregatorV3 has no confidence field");
        assertTrue(sourceTime != 0, "missing source publication time");

        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 1, 3 days);
        ValidatedMarkOracleAdapter adapter = new ValidatedMarkOracleAdapter(
            address(source), address(oracle), source.sourceScale(), 1, 3 days, 0
        );
        oracle.proposeUpdater(address(adapter));
        vm.prank(address(adapter));
        oracle.acceptUpdater();

        uint64 id = adapter.publish();
        assertEq(uint256(id), 2, "canonical observation not published");
        assertEq(
            uint256(oracle.markTick()),
            uint256(price) / source.sourceScale(),
            "incorrect canonical price tick"
        );
        assertEq(
            uint256(oracle.lastObservationTime()),
            uint256(sourceTime),
            "lost source-time provenance"
        );
    }
}

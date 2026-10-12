// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ChainlinkPriceSource} from "../src/ChainlinkPriceSource.sol";

contract ConfigurableFeedV3 {
    uint8 public immutable decimals;
    int256 public answer;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
    }

    function latestRoundData()
        external view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Records what the immutable feed-address validation can and cannot guarantee.
contract ChainlinkFeedIdentityConfigurationTest is TestBase {
    function _deploy(address feed, address sequencer, uint32 grace)
        external returns (ChainlinkPriceSource)
    {
        return new ChainlinkPriceSource(feed, sequencer, 60, grace);
    }

    function testRejectsEOAFeedAddress() public {
        (bool ok,) = address(this).call(
            abi.encodeCall(this._deploy, (address(0xBEEF), address(0), uint32(0)))
        );
        assertTrue(!ok, "EOA accepted as Chainlink feed");
    }

    function testRejectsUnsupportedFeedDecimals() public {
        ConfigurableFeedV3 bad = new ConfigurableFeedV3(19, 100e18);
        (bool ok,) = address(this).call(
            abi.encodeCall(this._deploy, (address(bad), address(0), uint32(0)))
        );
        assertTrue(!ok, "feed with unsupported decimals accepted");
    }

    function testRejectsMissingSequencerFeedWhenGraceConfigured() public {
        ConfigurableFeedV3 price = new ConfigurableFeedV3(8, 100e8);
        (bool ok,) = address(this).call(
            abi.encodeCall(this._deploy, (address(price), address(0), uint32(300)))
        );
        assertTrue(!ok, "sequencer grace accepted without uptime feed");
    }

    function testRejectsSequencerFeedWithoutGracePeriod() public {
        ConfigurableFeedV3 price = new ConfigurableFeedV3(8, 100e8);
        ConfigurableFeedV3 sequencer = new ConfigurableFeedV3(0, 0);
        (bool ok,) = address(this).call(
            abi.encodeCall(this._deploy, (address(price), address(sequencer), uint32(0)))
        );
        assertTrue(!ok, "sequencer accepted with zero grace period");
    }

    function testValidButWrongMarketFeedIsNotIdentifiedByContract() public {
        ConfigurableFeedV3 intended = new ConfigurableFeedV3(8, 100e8);
        ConfigurableFeedV3 wrongMarket = new ConfigurableFeedV3(8, 500e8);
        ChainlinkPriceSource source =
            new ChainlinkPriceSource(address(wrongMarket), address(0), 60, 0);

        (int256 published,,) = source.latestPrice();
        assertEq(published, int256(500e8), "configured wrong-market feed was not read");
        assertTrue(
            address(source.priceFeed()) != address(intended),
            "test did not configure distinct feeds"
        );
        // An attacker does not gain control merely by deploying this mock.
        // This documents the asset/quote mapping as an off-chain deployment obligation.
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainlink AggregatorV3-compatible price and L2 sequencer uptime interface.
interface IChainlinkAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
}

/// @title ChainlinkPriceSource
/// @notice On-chain source for ValidatedMarkOracleAdapter. Reads real Chainlink feeds
///         and rejects stale, incomplete, invalid, and sequencer-unsafe observations.
/// @dev Confidence is returned as zero because AggregatorV3 does not report confidence;
///      deployments must not interpret zero as independent confidence verification.
contract ChainlinkPriceSource {
    error InvalidConfiguration();
    error InvalidRound();
    error StaleRound();
    error SequencerUnavailable();

    IChainlinkAggregatorV3 public immutable priceFeed;
    IChainlinkAggregatorV3 public immutable sequencerFeed;
    uint256 public immutable sourceScale;
    uint32 public immutable heartbeat;
    uint32 public immutable sequencerGracePeriod;

    /// @param sequencerFeed_ Address(0) only for chains without an L2 sequencer requirement.
    /// @param heartbeat_ Maximum accepted age of the Chainlink price round in seconds.
    /// @param sequencerGracePeriod_ Minimum time since the sequencer resumed; zero on L1.
    constructor(
        address priceFeed_,
        address sequencerFeed_,
        uint32 heartbeat_,
        uint32 sequencerGracePeriod_
    ) {
        if (
            priceFeed_ == address(0) || priceFeed_.code.length == 0
                || heartbeat_ == 0
                || (sequencerFeed_ == address(0)) != (sequencerGracePeriod_ == 0)
        ) revert InvalidConfiguration();
        if (sequencerFeed_ != address(0) && sequencerFeed_.code.length == 0) {
            revert InvalidConfiguration();
        }

        IChainlinkAggregatorV3 feed = IChainlinkAggregatorV3(priceFeed_);
        uint8 decimals = feed.decimals();
        if (decimals > 18) revert InvalidConfiguration();

        priceFeed = feed;
        sequencerFeed = IChainlinkAggregatorV3(sequencerFeed_);
        sourceScale = 10 ** uint256(decimals);
        heartbeat = heartbeat_;
        sequencerGracePeriod = sequencerGracePeriod_;
    }

    /// @notice Returns an unmodified source price and source publication time.
    /// @dev Compatible with IExternalPriceSource in ValidatedMarkOracleAdapter.
    function latestPrice()
        external
        view
        returns (int256 price, uint256 confidence, uint48 publishTime)
    {
        if (address(sequencerFeed) != address(0)) {
            (
                uint80 sequencerRound, int256 sequencerAnswer, uint256 startedAt,
                uint256 sequencerUpdated, uint80 sequencerAnsweredInRound
            ) = sequencerFeed.latestRoundData();
            if (
                sequencerRound == 0 || sequencerAnsweredInRound < sequencerRound
                    || sequencerAnswer != 0 || startedAt == 0
                    || startedAt > block.timestamp || sequencerUpdated == 0
                    || sequencerUpdated > block.timestamp
                    || block.timestamp - startedAt <= sequencerGracePeriod
            ) revert SequencerUnavailable();
        }

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        if (
            roundId == 0 || answeredInRound < roundId || answer <= 0
                || updatedAt == 0 || updatedAt > block.timestamp
                || updatedAt > type(uint48).max
        ) revert InvalidRound();
        if (block.timestamp - updatedAt > heartbeat) revert StaleRound();

        price = answer;
        confidence = 0;
        publishTime = uint48(updatedAt);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IExternalPriceSource {
    /// @notice Returns price and absolute confidence in source units, plus publish time.
    function latestPrice()
        external
        view
        returns (int256 price, uint256 confidence, uint48 publishTime);
}

interface ITickObservationSink {
    function record(uint16 tick) external returns (uint64 observationId);
    function recordAt(uint16 tick, uint48 observationTime)
        external
        returns (uint64 observationId);
}

/// @title ValidatedMarkOracleAdapter
/// @notice Vendor-neutral validation and scale-normalization boundary for production mark prices.
/// @dev Validated prices are published into the canonical SegmentTreeExtremaOracle, so
///      matching and trailing-stop history continue to consume exactly the same mark source.
///      Source price/confidence share `sourceScale`. The normalized tick is
///      floor(price * ticksPerUnit / sourceScale).
contract ValidatedMarkOracleAdapter {
    error InvalidConfig();
    error InvalidPrice();
    error StalePrice();
    error FuturePrice();
    error ConfidenceTooWide();
    error TickOverflow();
    error NonMonotonicSourceTime();

    IExternalPriceSource public immutable source;
    ITickObservationSink public immutable sink;
    uint256 public immutable sourceScale;
    uint256 public immutable ticksPerUnit;
    uint32 public immutable maxAge;
    uint16 public immutable maxConfidenceBps;
    uint48 public lastSourcePublishTime;

    event PricePublished(
        uint64 indexed observationId,
        uint16 indexed tick,
        uint48 sourcePublishTime
    );

    constructor(
        address source_,
        address sink_,
        uint256 sourceScale_,
        uint256 ticksPerUnit_,
        uint32 maxAge_,
        uint16 maxConfidenceBps_
    ) {
        if (
            source_ == address(0) || sink_ == address(0) || sourceScale_ == 0
                || ticksPerUnit_ == 0 || maxAge_ == 0
                || maxConfidenceBps_ > 10_000
        ) revert InvalidConfig();

        source = IExternalPriceSource(source_);
        sink = ITickObservationSink(sink_);
        sourceScale = sourceScale_;
        ticksPerUnit = ticksPerUnit_;
        maxAge = maxAge_;
        maxConfidenceBps = maxConfidenceBps_;
    }

    function validatedTick()
        public
        view
        returns (uint16 tick, uint48 publishTime)
    {
        (int256 signedPrice, uint256 confidence, uint48 sourcePublishTime) =
            source.latestPrice();

        if (signedPrice <= 0) revert InvalidPrice();
        if (uint256(sourcePublishTime) > block.timestamp) revert FuturePrice();
        if (block.timestamp > uint256(sourcePublishTime) + uint256(maxAge)) {
            revert StalePrice();
        }

        uint256 price = uint256(signedPrice);
        if (
            confidence != 0
                && confidence * 10_000 > price * uint256(maxConfidenceBps)
        ) revert ConfidenceTooWide();

        uint256 normalized = price * ticksPerUnit / sourceScale;
        if (normalized > type(uint16).max) revert TickOverflow();

        tick = uint16(normalized);
        publishTime = sourcePublishTime;
    }

    /// @notice Permissionless relay. Only validated source data can reach the canonical sink.
    /// @dev The sink must configure this adapter as its updater.
    function publish() external returns (uint64 observationId) {
        (uint16 tick, uint48 publishTime) = validatedTick();
        if (publishTime <= lastSourcePublishTime) {
            revert NonMonotonicSourceTime();
        }

        lastSourcePublishTime = publishTime;
        observationId = sink.recordAt(tick, publishTime);
        emit PricePublished(observationId, tick, publishTime);
    }
}

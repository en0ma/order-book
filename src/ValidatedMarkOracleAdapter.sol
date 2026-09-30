// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMarkOracle} from "./interfaces/IMarkOracle.sol";

interface IExternalPriceSource {
    /// @notice Returns price and absolute confidence in source units, plus publish time.
    function latestPrice()
        external
        view
        returns (int256 price, uint256 confidence, uint48 publishTime);
}

/// @title ValidatedMarkOracleAdapter
/// @notice Vendor-neutral validation and scale-normalization boundary for production mark prices.
/// @dev Source price/confidence share `sourceScale`. The normalized tick is
///      floor(price * ticksPerUnit / sourceScale).
contract ValidatedMarkOracleAdapter is IMarkOracle {
    error InvalidConfig();
    error InvalidPrice();
    error StalePrice();
    error FuturePrice();
    error ConfidenceTooWide();
    error TickOverflow();

    IExternalPriceSource public immutable source;
    uint256 public immutable sourceScale;
    uint256 public immutable ticksPerUnit;
    uint32 public immutable maxAge;
    uint16 public immutable maxConfidenceBps;

    constructor(
        address source_,
        uint256 sourceScale_,
        uint256 ticksPerUnit_,
        uint32 maxAge_,
        uint16 maxConfidenceBps_
    ) {
        if (
            source_ == address(0) || sourceScale_ == 0 || ticksPerUnit_ == 0
                || maxAge_ == 0 || maxConfidenceBps_ > 10_000
        ) revert InvalidConfig();

        source = IExternalPriceSource(source_);
        sourceScale = sourceScale_;
        ticksPerUnit = ticksPerUnit_;
        maxAge = maxAge_;
        maxConfidenceBps = maxConfidenceBps_;
    }

    function markTick() external view override returns (uint16 tick) {
        (int256 signedPrice, uint256 confidence, uint48 publishTime) =
            source.latestPrice();

        if (signedPrice <= 0) revert InvalidPrice();
        if (uint256(publishTime) > block.timestamp) revert FuturePrice();
        if (block.timestamp > uint256(publishTime) + uint256(maxAge)) {
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
    }
}

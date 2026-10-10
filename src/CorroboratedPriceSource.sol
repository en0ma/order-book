// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IExternalPriceSource} from "./ValidatedMarkOracleAdapter.sol";

/// @title CorroboratedPriceSource
/// @notice Optional, vendor-neutral on-chain two-source deviation gate.
/// @dev Both sources must price the SAME asset and quote currency. Distinct contract
///      addresses do not by themselves prove independent providers or data origins.
///      This contract intentionally has no owner, bypass, or mutable price override.
contract CorroboratedPriceSource is IExternalPriceSource {
    error InvalidConfiguration();
    error InvalidSourceObservation();
    error SourceStale();
    error SourceDeviation();

    IExternalPriceSource public immutable primary;
    IExternalPriceSource public immutable referenceSource;
    uint256 public immutable primaryScale;
    uint256 public immutable referenceScale;
    uint32 public immutable maxAge;
    uint16 public immutable maxDeviationBps;

    constructor(
        address primary_, address reference_,
        uint256 primaryScale_, uint256 referenceScale_,
        uint32 maxAge_, uint16 maxDeviationBps_
    ) {
        if (
            primary_ == address(0) || reference_ == address(0)
                || primary_ == reference_
                || primary_.code.length == 0 || reference_.code.length == 0
                || primaryScale_ == 0 || referenceScale_ == 0
                || primaryScale_ > 1e18 || referenceScale_ > 1e18
                || maxAge_ == 0 || maxDeviationBps_ == 0
                || maxDeviationBps_ > 10_000
        ) revert InvalidConfiguration();
        primary = IExternalPriceSource(primary_);
        referenceSource = IExternalPriceSource(reference_);
        primaryScale = primaryScale_;
        referenceScale = referenceScale_;
        maxAge = maxAge_;
        maxDeviationBps = maxDeviationBps_;
    }

    function latestPrice()
        external view
        returns (int256 price, uint256 confidence, uint48 publishTime)
    {
        (int256 primaryPrice, uint256 primaryConfidence, uint48 primaryTime) =
            primary.latestPrice();
        (int256 referencePrice,, uint48 referenceTime) =
            referenceSource.latestPrice();

        if (primaryPrice <= 0 || referencePrice <= 0 ||
            primaryTime == 0 || referenceTime == 0 ||
            uint256(primaryTime) > block.timestamp ||
            uint256(referenceTime) > block.timestamp) {
            revert InvalidSourceObservation();
        }
        if (block.timestamp - uint256(primaryTime) > maxAge ||
            block.timestamp - uint256(referenceTime) > maxAge) {
            revert SourceStale();
        }

        // Cross multiplication preserves source precision without rounding away
        // a deviation. Checked arithmetic fails closed on extreme feed values.
        uint256 a = uint256(primaryPrice) * referenceScale;
        uint256 b = uint256(referencePrice) * primaryScale;
        uint256 difference = a >= b ? a - b : b - a;
        if (difference * 10_000 > b * uint256(maxDeviationBps)) {
            revert SourceDeviation();
        }
        // Preserve the primary source's price, confidence, and true timestamp.
        return (primaryPrice, primaryConfidence, primaryTime);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IExternalPriceSource} from "./ValidatedMarkOracleAdapter.sol";

/// @notice Explicit, fail-closed source recovery for a validated mark adapter.
/// @dev Both feeds MUST report identical price/confidence units for the configured market.
///      This router supplies no asset-pair or independence attestation; deployments must
///      verify both feeds before assigning the router to ValidatedMarkOracleAdapter.
contract ValidatedOracleSourceRouter is IExternalPriceSource {
    error InvalidConfig();
    error Unauthorized();
    error PrimaryStillHealthy();
    error UnhealthyCandidate();
    error AlreadySelected();

    IExternalPriceSource public immutable primary;
    IExternalPriceSource public immutable backup;
    address public immutable governance;
    uint32 public immutable maxAge;
    uint16 public immutable maxConfidenceBps;
    bool public usingBackup;

    event OracleSourceSelected(address indexed source, bool usingBackup);

    constructor(
        address primary_,
        address backup_,
        uint32 maxAge_,
        uint16 maxConfidenceBps_
    ) {
        if (
            primary_ == address(0) || backup_ == address(0)
                || primary_ == backup_ || primary_.code.length == 0
                || backup_.code.length == 0 || maxAge_ == 0
                || maxConfidenceBps_ > 10_000
        ) revert InvalidConfig();

        primary = IExternalPriceSource(primary_);
        backup = IExternalPriceSource(backup_);
        governance = msg.sender;
        maxAge = maxAge_;
        maxConfidenceBps = maxConfidenceBps_;
    }

    function activeSource() public view returns (IExternalPriceSource) {
        return usingBackup ? backup : primary;
    }

    function latestPrice()
        external
        view
        returns (int256 price, uint256 confidence, uint48 publishTime)
    {
        return activeSource().latestPrice();
    }

    /// @notice Governance may move to backup only when the primary is unhealthy.
    /// @dev Failover does not mint a fresh timestamp or relax adapter validation.
    function activateBackup() external {
        if (msg.sender != governance) revert Unauthorized();
        if (usingBackup) revert AlreadySelected();
        if (_healthy(primary)) revert PrimaryStillHealthy();
        if (!_healthy(backup)) revert UnhealthyCandidate();
        usingBackup = true;
        emit OracleSourceSelected(address(backup), true);
    }

    /// @notice Governance may restore a validated healthy primary; never automatic.
    function restorePrimary() external {
        if (msg.sender != governance) revert Unauthorized();
        if (!usingBackup) revert AlreadySelected();
        if (!_healthy(primary)) revert UnhealthyCandidate();
        usingBackup = false;
        emit OracleSourceSelected(address(primary), false);
    }

    function primaryHealthy() external view returns (bool) {
        return _healthy(primary);
    }

    function backupHealthy() external view returns (bool) {
        return _healthy(backup);
    }

    function _healthy(IExternalPriceSource candidate) internal view returns (bool) {
        try candidate.latestPrice() returns (
            int256 signedPrice,
            uint256 confidence,
            uint48 publishTime
        ) {
            if (signedPrice <= 0 || uint256(publishTime) > block.timestamp) return false;
            if (block.timestamp - uint256(publishTime) > maxAge) return false;
            uint256 price = uint256(signedPrice);
            // Division avoids overflow on attacker-controlled confidence and price.
            return confidence <= price * uint256(maxConfidenceBps) / 10_000;
        } catch {
            return false;
        }
    }
}

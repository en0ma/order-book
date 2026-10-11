// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Optional bounded funding authority. Assign this contract as the Core funding updater.
/// @dev No oracle vendor, funding formula, or matching contract changes are required.
interface IFundingIndexCore {
    function fundingIndexX18() external view returns (int128);
    function setFundingIndex(int128 nextFundingIndexX18) external;
    function setRiskIncreasePaused(bool paused) external;
}

contract BoundedFundingUpdater {
    error InvalidConfig();
    error Unauthorized();
    error UpdateTooEarly();
    error FundingDeltaTooLarge();
    error FundingIndexChangedExternally();

    IFundingIndexCore public immutable core;
    address public immutable operator;
    uint256 public immutable minIntervalSeconds;
    uint256 public immutable maxAbsDeltaX18;
    uint256 public lastUpdateTime;
    int128 public lastIndexX18;

    event BoundedFundingUpdated(int128 previousIndex, int128 nextIndex, uint256 time);

    constructor(address core_, address operator_, uint256 minInterval_, uint256 maxDelta_) {
        if (
            core_ == address(0) || core_.code.length == 0 || operator_ == address(0)
                || minInterval_ == 0 || maxDelta_ == 0 || maxDelta_ > uint256(uint128(type(int128).max))
        ) revert InvalidConfig();
        core = IFundingIndexCore(core_);
        operator = operator_;
        minIntervalSeconds = minInterval_;
        maxAbsDeltaX18 = maxDelta_;
        lastIndexX18 = IFundingIndexCore(core_).fundingIndexX18();
        lastUpdateTime = block.timestamp;
    }

    /// @notice Operator-only, one-way emergency risk-off forwarding; unpause stays with Core owner.
    function pauseRiskIncrease() external {
        if (msg.sender != operator) revert Unauthorized();
        core.setRiskIncreasePaused(true);
    }

    function publish(int128 nextIndex) external {
        if (msg.sender != operator) revert Unauthorized();
        uint256 elapsed = block.timestamp - lastUpdateTime;
        if (elapsed < minIntervalSeconds) revert UpdateTooEarly();

        // Never silently overwrite funding published through a different authority.
        int128 previous = core.fundingIndexX18();
        if (previous != lastIndexX18) revert FundingIndexChangedExternally();

        int256 signedDelta = int256(nextIndex) - int256(previous);
        uint256 delta = uint256(signedDelta < 0 ? -signedDelta : signedDelta);
        if (delta > maxAbsDeltaX18) revert FundingDeltaTooLarge();

        lastIndexX18 = nextIndex;
        lastUpdateTime = block.timestamp;
        core.setFundingIndex(nextIndex);
        emit BoundedFundingUpdated(previous, nextIndex, block.timestamp);
    }
}

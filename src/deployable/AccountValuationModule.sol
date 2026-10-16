// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pure signed mark-to-market math outside deployable Core runtime.
/// @dev Exact same integer operation order and checked-arithmetic semantics
/// as the former Core.accountMarketValue implementation.
contract AccountValuationModule {
    function marketValue(
        int80 position,
        int128 index,
        int128 checkpoint,
        uint16 markTick,
        uint128 unitScale,
        int256 trade,
        int256 funding
    ) external pure returns (int256) {
        int256 pendingFunding =
            -(int256(position) * (int256(index) - int256(checkpoint)) / 1e18);
        int256 markedPositionValue;
        if (position != 0) {
            uint96 lots = uint96(uint256(position > 0 ? int256(position) : -int256(position)));
            int256 marked = int256(
                uint256(lots) * uint256(markTick) * uint256(unitScale)
            );
            markedPositionValue = position > 0 ? marked : -marked;
        }
        return trade + funding + pendingFunding + markedPositionValue;
    }
}

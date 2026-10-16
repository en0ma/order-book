// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClaimantRegistry} from "./ClaimantRegistry.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

interface IRewardPayoutCore {
    function claimantRegistry() external view returns (ClaimantRegistry);
    function protocolFeesAccrued() external view returns (uint256);
    function collateralAsset() external view returns (address);
    function moduleExecuteLiquidationReward(address liquidator, uint256 amount) external;
}

/// @notice Immutable liquidation reward proof orchestration, executed only
/// through Core's advanced-module-checked, guarded delegatecall.
contract LiquidationRewardPayoutModule {
    error RewardBackingInsufficient();

    function execute(address liquidator, uint256 requested)
        external returns (uint256 paid)
    {
        IRewardPayoutCore core = IRewardPayoutCore(address(this));
        uint256 accrued = core.protocolFeesAccrued();
        paid = requested < accrued ? requested : accrued;
        if (paid == 0) return 0;

        uint256 available;
        try core.claimantRegistry().conservativeRewardCapacity() returns (
            uint256 capacity, uint256, uint256
        ) {
            available = capacity;
        } catch {
            return 0;
        }
        if (paid > available) paid = available;
        if (paid == 0) return 0;

        core.moduleExecuteLiquidationReward(liquidator, paid);

        (,, uint256 remainingLiabilities) =
            core.claimantRegistry().conservativeRewardCapacity();
        if (IERC20Minimal(core.collateralAsset()).balanceOf(address(core)) < remainingLiabilities) {
            revert RewardBackingInsufficient();
        }
    }
}

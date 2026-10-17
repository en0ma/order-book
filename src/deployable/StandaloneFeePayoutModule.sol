// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClaimantRegistry} from "./ClaimantRegistry.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

/// @notice Immutable standalone treasury proof implementation, run only by
/// Core's owner-checked, reentrancy-guarded delegatecall entrypoint.
/// @dev No independent storage or mutable destinations. Calls back into the
/// exact delegating Core for an atomic, self-authorized ledger/token debit.
interface IStandaloneFeePayoutCore {
    function claimantRegistry() external view returns (ClaimantRegistry);
    function collateralAsset() external view returns (address);
    function treasuryRecipient() external view returns (address);
    function moduleExecuteTreasuryFeePayout(uint256 amount) external;
}

contract StandaloneFeePayoutModule {
    error InsufficientFeeBacking();

    function execute(uint256 amount) external {
        IStandaloneFeePayoutCore core = IStandaloneFeePayoutCore(address(this));
        (uint256 available,,) = core.claimantRegistry().standaloneFeeCapacity();
        if (amount > available) revert InsufficientFeeBacking();

        core.moduleExecuteTreasuryFeePayout(amount);

        (,, uint256 protectedLiabilities) =
            core.claimantRegistry().standaloneFeeCapacity();
        if (
            IERC20Minimal(core.collateralAsset()).balanceOf(address(core))
                < protectedLiabilities
        ) revert InsufficientFeeBacking();
    }
}

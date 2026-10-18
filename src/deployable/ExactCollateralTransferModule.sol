// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

interface ICollateralTransferContext {
    function collateralAsset() external view returns (address);
}

/// @notice Shared exact ERC20 transfer logic executed through Core delegatecall.
/// @dev ERC20 calls originate from the delegating Core, never this helper.
contract ExactCollateralTransferModule {
    error TokenTransferFailed();
    error UnsupportedTokenBehavior();

    function transferExact(address recipient, uint256 amount) external {
        IERC20Minimal token = IERC20Minimal(
            ICollateralTransferContext(address(this)).collateralAsset()
        );
        uint256 custodyBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(recipient);
        if (!token.transfer(recipient, amount)) revert TokenTransferFailed();
        uint256 custodyAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(recipient);
        if (
            custodyBefore < amount || custodyAfter != custodyBefore - amount
                || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert UnsupportedTokenBehavior();
    }
}

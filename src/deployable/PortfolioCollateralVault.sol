// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

/// @title PortfolioCollateralVault
/// @notice Shared ERC-20 custody for portfolio-margin deployments.
/// @dev The controller may only lock/unlock collateral; it cannot transfer user funds.
///      User withdrawals are limited to unlocked collateral, and all accounted balances
///      remain fully token-backed.
contract PortfolioCollateralVault {
    error ZeroAmount();
    error Unauthorized();
    error InvalidController();
    error ControllerAlreadyConfigured();
    error InsufficientFreeCollateral();
    error TokenTransferFailed();
    error UnsupportedTokenBehavior();

    IERC20Minimal public immutable collateralToken;
    address public immutable owner;
    address public controller;

    uint256 public totalAccountedCollateral;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lockedCollateral;

    event ControllerConfigured(address indexed controller);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event LockedCollateralUpdated(
        address indexed account,
        uint256 previousLocked,
        uint256 nextLocked
    );
    event ExcessSwept(address indexed recipient, uint256 amount);

    constructor(address collateralToken_) {
        if (collateralToken_ == address(0)) revert TokenTransferFailed();
        collateralToken = IERC20Minimal(collateralToken_);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyController() {
        if (msg.sender != controller || msg.sender == address(0)) revert Unauthorized();
        _;
    }

    function configureController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert InvalidController();
        if (controller != address(0)) revert ControllerAlreadyConfigured();
        controller = controller_;
        emit ControllerConfigured(controller_);
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        IERC20Minimal token = collateralToken;
        uint256 beforeBalance = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount)) {
            revert TokenTransferFailed();
        }

        uint256 received = token.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert UnsupportedTokenBehavior();

        balanceOf[msg.sender] += amount;
        totalAccountedCollateral += amount;

        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 balance = balanceOf[msg.sender];
        uint256 locked = lockedCollateral[msg.sender];
        if (amount > balance - locked) revert InsufficientFreeCollateral();

        unchecked {
            balanceOf[msg.sender] = balance - amount;
            totalAccountedCollateral -= amount;
        }

        if (!collateralToken.transfer(msg.sender, amount)) {
            revert TokenTransferFailed();
        }

        emit Withdrawn(msg.sender, amount);
    }

    function setLockedCollateral(address account, uint256 nextLocked)
        external
        onlyController
    {
        if (nextLocked > balanceOf[account]) revert InsufficientFreeCollateral();

        uint256 previousLocked = lockedCollateral[account];
        if (previousLocked == nextLocked) return;

        lockedCollateral[account] = nextLocked;
        emit LockedCollateralUpdated(account, previousLocked, nextLocked);
    }

    function freeCollateral(address account) external view returns (uint256) {
        return balanceOf[account] - lockedCollateral[account];
    }

    function excessTokenBalance() public view returns (uint256) {
        uint256 actual = collateralToken.balanceOf(address(this));
        return actual > totalAccountedCollateral
            ? actual - totalAccountedCollateral
            : 0;
    }

    function sweepExcess(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0) || amount == 0) revert ZeroAmount();
        if (amount > excessTokenBalance()) revert InsufficientFreeCollateral();
        if (!collateralToken.transfer(recipient, amount)) {
            revert TokenTransferFailed();
        }
        emit ExcessSwept(recipient, amount);
    }
}

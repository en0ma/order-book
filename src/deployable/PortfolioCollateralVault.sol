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
    mapping(address => uint256) public portfolioWithdrawn;
    mapping(address => uint256) public lockedCollateral;

    event ControllerConfigured(address indexed controller);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event PortfolioWithdrawn(
        address indexed account,
        address indexed recipient,
        uint256 amount
    );
    event SystemWithdrawn(address indexed recipient, uint256 amount);
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
        if (controller != address(0)) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = balanceOf[msg.sender];
        if (amount > balance) revert InsufficientFreeCollateral();

        unchecked {
            balanceOf[msg.sender] = balance - amount;
            totalAccountedCollateral -= amount;
        }

        if (!collateralToken.transfer(msg.sender, amount)) {
            revert TokenTransferFailed();
        }

        emit Withdrawn(msg.sender, amount);
    }

    function controllerWithdraw(
        address account,
        address recipient,
        uint256 amount
    ) external onlyController {
        if (recipient == address(0) || amount == 0) revert ZeroAmount();
        if (amount > totalAccountedCollateral) revert InsufficientFreeCollateral();

        portfolioWithdrawn[account] += amount;
        totalAccountedCollateral -= amount;

        if (!collateralToken.transfer(recipient, amount)) {
            revert TokenTransferFailed();
        }

        emit PortfolioWithdrawn(account, recipient, amount);
    }

    function controllerSystemWithdraw(address recipient, uint256 amount)
        external
        onlyController
    {
        if (recipient == address(0) || amount == 0) revert ZeroAmount();
        if (amount > totalAccountedCollateral) revert InsufficientFreeCollateral();

        totalAccountedCollateral -= amount;
        if (!collateralToken.transfer(recipient, amount)) {
            revert TokenTransferFailed();
        }

        emit SystemWithdrawn(recipient, amount);
    }

    function collateralClaim(address account) public view returns (int256 claim) {
        uint256 balance = balanceOf[account];
        uint256 withdrawn = portfolioWithdrawn[account];

        if (balance >= withdrawn) {
            uint256 positive = balance - withdrawn;
            if (positive > uint256(type(int256).max)) revert InsufficientFreeCollateral();
            return int256(positive);
        }

        uint256 deficit = withdrawn - balance;
        if (deficit > uint256(type(int256).max)) revert InsufficientFreeCollateral();
        return -int256(deficit);
    }

    function setLockedCollateral(address account, uint256 nextLocked)
        external
        onlyController
    {
        int256 claim = collateralClaim(account);
        uint256 positiveClaim = claim > 0 ? uint256(claim) : 0;
        if (nextLocked > positiveClaim) revert InsufficientFreeCollateral();

        uint256 previousLocked = lockedCollateral[account];
        if (previousLocked == nextLocked) return;

        lockedCollateral[account] = nextLocked;
        emit LockedCollateralUpdated(account, previousLocked, nextLocked);
    }

    function freeCollateral(address account) external view returns (uint256) {
        int256 claim = collateralClaim(account);
        if (claim <= 0) return 0;

        uint256 positiveClaim = uint256(claim);
        uint256 locked = lockedCollateral[account];
        return positiveClaim > locked ? positiveClaim - locked : 0;
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

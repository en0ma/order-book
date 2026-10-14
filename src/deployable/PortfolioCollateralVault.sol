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
    error ReentrantCustodyCall();

    IERC20Minimal public immutable collateralToken;
    address public owner;
    address public controller;

    uint256 private _custodyEntered;

    modifier nonReentrantCustody() {
        if (_custodyEntered != 0) revert ReentrantCustodyCall();
        _custodyEntered = 1;
        _;
        _custodyEntered = 0;
    }

    uint256 public totalAccountedCollateral;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public portfolioWithdrawn;
    mapping(address => uint256) public lockedCollateral;

    event OwnershipTransferred(address indexed previousOwner, address indexed nextOwner);
    event ControllerConfigured(address indexed controller);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event PortfolioWithdrawn(
        address indexed account,
        address indexed recipient,
        uint256 amount
    );
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

    function transferOwnership(address nextOwner) external onlyOwner {
        if (nextOwner == address(0)) revert Unauthorized();
        address previousOwner = owner;
        owner = nextOwner;
        emit OwnershipTransferred(previousOwner, nextOwner);
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

    function deposit(uint256 amount) external nonReentrantCustody {
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

    function withdraw(uint256 amount) external nonReentrantCustody {
        if (controller != address(0)) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = balanceOf[msg.sender];
        if (amount > balance) revert InsufficientFreeCollateral();

        unchecked {
            balanceOf[msg.sender] = balance - amount;
            totalAccountedCollateral -= amount;
        }

        _transferExact(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function controllerWithdraw(
        address account,
        address recipient,
        uint256 amount
    ) external onlyController nonReentrantCustody {
        if (recipient == address(0) || amount == 0) revert ZeroAmount();
        if (amount > totalAccountedCollateral) revert InsufficientFreeCollateral();
        // The controller may disburse realized portfolio profits, but it must
        // not invalidate the account's existing collateral lock.
        int256 claim = collateralClaim(account);
        if (claim > 0) {
            uint256 locked = lockedCollateral[account];
            if (locked > 0 && uint256(claim) < amount + locked) {
                revert InsufficientFreeCollateral();
            }
        } else if (lockedCollateral[account] != 0) {
            revert InsufficientFreeCollateral();
        }

        portfolioWithdrawn[account] += amount;
        totalAccountedCollateral -= amount;

        _transferExact(recipient, amount);

        emit PortfolioWithdrawn(account, recipient, amount);
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

    function sweepExcess(address recipient, uint256 amount) external onlyOwner nonReentrantCustody {
        // The raw ERC-20 balance above deposited principal is not proven
        // surplus when portfolio positions can earn unsettled profits.
        // Disable owner extraction for controller-managed custody until a
        // globally reconciled net-liability proof exists.
        if (controller != address(0)) revert Unauthorized();
        if (recipient == address(0) || amount == 0) revert ZeroAmount();
        if (amount > excessTokenBalance()) revert InsufficientFreeCollateral();
        _transferExact(recipient, amount);
        emit ExcessSwept(recipient, amount);
    }

    function _transferExact(address recipient, uint256 amount) internal {
        IERC20Minimal token = collateralToken;
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(recipient);
        if (!token.transfer(recipient, amount)) revert TokenTransferFailed();
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(recipient);
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
            revert UnsupportedTokenBehavior();
        }
        // A burn/tax on receipt otherwise silently destroys the withdrawing
        // user's claim despite an exact debit from vault custody.
        if (recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount) {
            revert UnsupportedTokenBehavior();
        }
        if (afterBalance < totalAccountedCollateral) revert UnsupportedTokenBehavior();
    }
}

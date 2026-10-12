// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {TestBase} from "./TestBase.sol";

/// @dev ERC-20 test double that invokes a recipient hook during outgoing transfers.
contract CallbackCollateral {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public callbackEnabled;
    bool public callbackAttempted;
    bool public callbackSucceeded;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function setCallbackEnabled(bool enabled) external { callbackEnabled = enabled; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (callbackEnabled && to.code.length != 0) {
            callbackEnabled = false;
            callbackAttempted = true;
            (callbackSucceeded,) = to.call(abi.encodeWithSignature("onTokenReceived()"));
        }
        return true;
    }
}

contract CallbackWithdrawer {
    CallbackCollateral public immutable token;
    address public immutable target;
    bool public immutable vaultMode;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(CallbackCollateral token_, address target_, bool vaultMode_) {
        token = token_;
        target = target_;
        vaultMode = vaultMode_;
    }
    function enter(uint256 depositAmount, uint256 withdrawAmount) external {
        token.approve(target, depositAmount);
        if (vaultMode) {
            PortfolioCollateralVault(target).deposit(depositAmount);
        } else {
            OrderBookCore(target).depositCollateral(depositAmount);
        }
        token.setCallbackEnabled(true);
        if (vaultMode) {
            PortfolioCollateralVault(target).withdraw(withdrawAmount);
        } else {
            OrderBookCore(target).withdrawCollateral(withdrawAmount);
        }
    }
    function onTokenReceived() external {
        require(msg.sender == address(token), "not token");
        reentered = true;
        if (vaultMode) {
            (reentrySucceeded,) = target.call(
                abi.encodeWithSelector(PortfolioCollateralVault.withdraw.selector, uint256(100))
            );
        } else {
            (reentrySucceeded,) = target.call(
                abi.encodeWithSelector(OrderBookCore.withdrawCollateral.selector, uint256(100))
            );
        }
    }
}

contract AdversarialCollateralCallbackTest is TestBase {
    function testStandaloneDoubleWithdrawCallbackCannotOverdraw() public {
        CallbackCollateral token = new CallbackCollateral();
        OrderBookCore core = new OrderBookCore(
            address(token), address(new MockMarkOracle(100)), 30, 1000, 0, 0
        );
        CallbackWithdrawer trader = new CallbackWithdrawer(token, address(core), false);
        token.mint(address(trader), 100);
        trader.enter(100, 100);
        assertTrue(trader.reentered(), "callback not exercised");
        assertTrue(!trader.reentrySucceeded(), "recursive withdrawal overdraw succeeded");
        assertEq(token.balanceOf(address(trader)), 100, "trader withdrew more than deposited");
        assertEq(token.balanceOf(address(core)), 0, "remaining custody incorrect");
        assertEq(core.accountEquity(address(trader)), int256(0), "account equity not cleared");
    }

    function testPortfolioVaultDoubleWithdrawCallbackCannotOverdraw() public {
        CallbackCollateral token = new CallbackCollateral();
        PortfolioCollateralVault vault = new PortfolioCollateralVault(address(token));
        CallbackWithdrawer trader = new CallbackWithdrawer(token, address(vault), true);
        token.mint(address(trader), 100);
        trader.enter(100, 100);
        assertTrue(trader.reentered(), "callback not exercised");
        assertTrue(!trader.reentrySucceeded(), "recursive withdrawal overdraw succeeded");
        assertEq(token.balanceOf(address(trader)), 100, "trader withdrew more than deposited");
        assertEq(token.balanceOf(address(vault)), 0, "remaining custody incorrect");
        assertEq(vault.balanceOf(address(trader)), 0, "ledger not cleared");
        assertEq(vault.totalAccountedCollateral(), 0, "accounting inflated");
    }
}

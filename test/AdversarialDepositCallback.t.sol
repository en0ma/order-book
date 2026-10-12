// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @notice Hostile collateral invokes sender during transferFrom, while custody is moving.
contract DepositHookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public hookEnabled;
    bool public hookAttempted;
    bool public hookSucceeded;

    function mint(address account, uint256 amount) external { balanceOf[account] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function enableHook() external { hookEnabled = true; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (hookEnabled && from.code.length > 0) {
            hookEnabled = false;
            hookAttempted = true;
            (hookSucceeded,) = from.call(abi.encodeWithSignature("onDepositTransfer()"));
        }
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DepositCallbackTrader {
    DepositHookToken public immutable token;
    address public immutable target;
    bool public immutable vaultMode;
    uint256 public callbackWithdrawAmount;

    constructor(DepositHookToken token_, address target_, bool vaultMode_) {
        token = token_;
        target = target_;
        vaultMode = vaultMode_;
        token.approve(target_, type(uint256).max);
    }
    function deposit(uint256 amount, uint256 callbackAmount) external returns (bool) {
        callbackWithdrawAmount = callbackAmount;
        token.enableHook();
        if (vaultMode) {
            (bool ok,) = target.call(abi.encodeWithSelector(PortfolioCollateralVault.deposit.selector, amount));
            return ok;
        }
        (bool ok,) = target.call(abi.encodeWithSelector(OrderBookCore.depositCollateral.selector, amount));
        return ok;
    }
    function onDepositTransfer() external {
        require(msg.sender == address(token), "not collateral");
        if (vaultMode) {
            PortfolioCollateralVault(target).withdraw(callbackWithdrawAmount);
        } else {
            OrderBookCore(target).withdrawCollateral(callbackWithdrawAmount);
        }
    }
}

/// @dev With no existing credit, the callback is rejected and the deposit succeeds.
///      Existing credit is tested separately: a successful nested withdrawal changes the
///      inbound balance delta, so the outer deposit must revert atomically.
contract AdversarialDepositCallbackCoreTest is TestBase {
    DepositHookToken internal token;
    OrderBookCore internal core;
    DepositCallbackTrader internal trader;

    function setUp() public {
        token = new DepositHookToken();
        core = new OrderBookCore(address(token), address(new MockMarkOracle(100)), 30, 1000, 0, 0);
        trader = new DepositCallbackTrader(token, address(core), false);
        token.mint(address(trader), 200);
    }

    function testUncreditedWithdrawalCallbackCannotDrainCore() public {
        assertTrue(trader.deposit(100, 100), "first deposit rejected");
        assertTrue(token.hookAttempted(), "deposit callback was not exercised");
        assertTrue(!token.hookSucceeded(), "uncredited callback withdrew funds");
        assertEq(token.balanceOf(address(core)), 100, "custody not backed");
        assertEq(core.accountEquity(address(trader)), int256(100), "account not credited once");
    }

    function testPriorCreditWithdrawDuringDepositRevertsAtomically() public {
        assertTrue(trader.deposit(100, 100), "initial deposit failed");
        uint256 beforeBalance = token.balanceOf(address(core));
        uint256 beforeTrader = token.balanceOf(address(trader));
        assertTrue(!trader.deposit(50, 25), "deposit with successful nested withdrawal accepted");
        assertEq(token.balanceOf(address(core)), beforeBalance, "failed deposit changed custody");
        assertEq(token.balanceOf(address(trader)), beforeTrader, "failed deposit moved funds");
        assertEq(core.accountEquity(address(trader)), int256(100), "failed deposit changed ledger");
    }
}

contract AdversarialDepositCallbackVaultTest is TestBase {
    DepositHookToken internal token;
    PortfolioCollateralVault internal vault;
    DepositCallbackTrader internal trader;

    function setUp() public {
        token = new DepositHookToken();
        vault = new PortfolioCollateralVault(address(token));
        trader = new DepositCallbackTrader(token, address(vault), true);
        token.mint(address(trader), 200);
    }

    function testUncreditedWithdrawalCallbackCannotDrainVault() public {
        assertTrue(trader.deposit(100, 100), "first deposit rejected");
        assertTrue(token.hookAttempted(), "deposit callback was not exercised");
        assertTrue(!token.hookSucceeded(), "uncredited callback withdrew funds");
        assertEq(token.balanceOf(address(vault)), 100, "custody not backed");
        assertEq(vault.balanceOf(address(trader)), 100, "account not credited once");
    }

    function testPriorCreditWithdrawDuringDepositRevertsAtomically() public {
        assertTrue(trader.deposit(100, 100), "initial deposit failed");
        uint256 beforeBalance = token.balanceOf(address(vault));
        uint256 beforeTrader = token.balanceOf(address(trader));
        assertTrue(!trader.deposit(50, 25), "deposit with successful nested withdrawal accepted");
        assertEq(token.balanceOf(address(vault)), beforeBalance, "failed deposit changed custody");
        assertEq(token.balanceOf(address(trader)), beforeTrader, "failed deposit moved funds");
        assertEq(vault.balanceOf(address(trader)), 100, "failed deposit changed ledger");
        assertEq(vault.totalAccountedCollateral(), 100, "total accounted collateral changed");
    }
}

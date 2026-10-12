// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @dev During transferFrom, token calls sender before the incoming deposit is credited.
contract InboundCallbackToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public callbackArmed;
    bool public callbackAttempted;
    bool public callbackReturned;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function arm() external { callbackArmed = true; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (callbackArmed && from.code.length > 0) {
            callbackArmed = false;
            callbackAttempted = true;
            (callbackReturned,) = from.call(abi.encodeWithSignature("onDepositCallback()"));
        }
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract InboundCallbackAccount {
    InboundCallbackToken internal immutable token;
    address internal immutable target;
    bool internal immutable portfolioMode;
    bool public callbackSeen;
    bool public uncreditedWithdrawSucceeded;

    constructor(InboundCallbackToken token_, address target_, bool portfolioMode_) {
        token = token_; target = target_; portfolioMode = portfolioMode_;
        token.approve(target_, type(uint256).max);
    }

    function deposit(uint256 amount, bool attack) external {
        if (attack) token.arm();
        if (portfolioMode) PortfolioCollateralVault(target).deposit(amount);
        else OrderBookCore(target).depositCollateral(amount);
    }

    function onDepositCallback() external {
        require(msg.sender == address(token), "only collateral token");
        callbackSeen = true;
        // Existing credited collateral: 100; in-flight deposit: 100.
        // With accounting before token receipt, 150 could incorrectly be withdrawn.
        if (portfolioMode) {
            (uncreditedWithdrawSucceeded,) = target.call(
                abi.encodeWithSelector(PortfolioCollateralVault.withdraw.selector, uint256(150))
            );
        } else {
            (uncreditedWithdrawSucceeded,) = target.call(
                abi.encodeWithSelector(OrderBookCore.withdrawCollateral.selector, uint256(150))
            );
        }
    }
}

contract InboundCoreCallbackTest is TestBase {
    InboundCallbackToken internal token;
    OrderBookCore internal core;
    InboundCallbackAccount internal attacker;

    function setUp() public {
        token = new InboundCallbackToken();
        core = new OrderBookCore(
            address(token), address(new MockMarkOracle(100)), 30, 1000, 0, 0
        );
        attacker = new InboundCallbackAccount(token, address(core), false);
        token.mint(address(attacker), 200);
        token.mint(address(0xCAFE), 300);
        vm.prank(address(0xCAFE));
        token.approve(address(core), 300);
        vm.prank(address(0xCAFE));
        core.depositCollateral(300);
        attacker.deposit(100, false);
    }

    function testDepositCallbackCannotWithdrawUncreditedCollateral() public {
        attacker.deposit(100, true);
        assertTrue(token.callbackAttempted(), "token callback not invoked");
        assertTrue(token.callbackReturned(), "callback reverted");
        assertTrue(attacker.callbackSeen(), "attacker callback not reached");
        assertTrue(!attacker.uncreditedWithdrawSucceeded(), "uncredited collateral withdrawn");
        assertEq(token.balanceOf(address(core)), 500, "pooled custody changed");
        assertEq(core.accountEquity(address(attacker)), int256(200), "attacker equity mismatch");
    }
}

contract InboundVaultCallbackTest is TestBase {
    InboundCallbackToken internal token;
    PortfolioCollateralVault internal vault;
    InboundCallbackAccount internal attacker;

    function setUp() public {
        token = new InboundCallbackToken();
        vault = new PortfolioCollateralVault(address(token));
        attacker = new InboundCallbackAccount(token, address(vault), true);
        token.mint(address(attacker), 200);
        token.mint(address(0xCAFE), 300);
        vm.prank(address(0xCAFE));
        token.approve(address(vault), 300);
        vm.prank(address(0xCAFE));
        vault.deposit(300);
        attacker.deposit(100, false);
    }

    function testDepositCallbackCannotWithdrawUncreditedCollateral() public {
        attacker.deposit(100, true);
        assertTrue(token.callbackAttempted(), "token callback not invoked");
        assertTrue(token.callbackReturned(), "callback reverted");
        assertTrue(attacker.callbackSeen(), "attacker callback not reached");
        assertTrue(!attacker.uncreditedWithdrawSucceeded(), "uncredited collateral withdrawn");
        assertEq(token.balanceOf(address(vault)), 500, "pooled custody changed");
        assertEq(vault.balanceOf(address(attacker)), 200, "attacker ledger mismatch");
        assertEq(vault.totalAccountedCollateral(), 500, "total custody mismatch");
    }
}

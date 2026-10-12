// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @dev Reentrant transferFrom occurs *after* token custody has moved.
contract RecursiveDepositToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public hookEnabled;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
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
        if (hookEnabled) {
            hookEnabled = false;
            (bool ok,) = from.call(abi.encodeWithSignature("onDepositTransfer()"));
            require(ok, "nested operation failed");
        }
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RecursiveDepositActor {
    RecursiveDepositToken public immutable token;
    address public immutable target;
    bool public immutable vaultMode;
    bool public insuranceMode;

    constructor(RecursiveDepositToken token_, address target_, bool vaultMode_) {
        token = token_;
        target = target_;
        vaultMode = vaultMode_;
        token.approve(target_, type(uint256).max);
    }

    function depositWithCallback(uint256 amount, bool insuranceMode_) external {
        insuranceMode = insuranceMode_;
        token.enableHook();
        if (vaultMode) PortfolioCollateralVault(target).deposit(amount);
        else OrderBookCore(target).depositCollateral(amount);
    }

    function onDepositTransfer() external {
        require(msg.sender == address(token), "not token");
        if (insuranceMode) OrderBookCore(target).fundInsurance(40);
        else if (vaultMode) PortfolioCollateralVault(target).deposit(40);
        else OrderBookCore(target).depositCollateral(40);
    }
}

contract RecursiveDepositCoreTest is TestBase {
    RecursiveDepositToken internal token;
    OrderBookCore internal core;
    RecursiveDepositActor internal actor;

    function setUp() public {
        token = new RecursiveDepositToken();
        core = new OrderBookCore(address(token), address(new MockMarkOracle(100)), 30, 1000, 0, 0);
        actor = new RecursiveDepositActor(token, address(core), false);
        token.mint(address(actor), 200);
        address sponsor = address(0xCAFE);
        token.mint(sponsor, 300);
        vm.prank(sponsor);
        token.approve(address(core), 300);
        vm.prank(sponsor);
        core.depositCollateral(300);
    }

    function testRecursiveDepositRevertsWithoutDoubleCredit() public {
        vm.expectRevert(OrderBookCore.UnsupportedTokenBehavior.selector);
        actor.depositWithCallback(100, false);
        assertEq(token.balanceOf(address(actor)), 200, "actor tokens moved");
        assertEq(token.balanceOf(address(core)), 300, "sponsor custody changed");
        assertEq(core.accountEquity(address(actor)), int256(0), "account gained credit");
    }

    function testCrossFunctionInsuranceFundingRevertsAtomically() public {
        vm.expectRevert(OrderBookCore.UnsupportedTokenBehavior.selector);
        actor.depositWithCallback(100, true);
        assertEq(token.balanceOf(address(actor)), 200, "actor tokens moved");
        assertEq(token.balanceOf(address(core)), 300, "sponsor custody changed");
        assertEq(core.insuranceReserves(), 0, "insurance credited");
        assertEq(core.accountEquity(address(actor)), int256(0), "account credited");
    }
}

contract RecursiveDepositVaultTest is TestBase {
    RecursiveDepositToken internal token;
    PortfolioCollateralVault internal vault;
    RecursiveDepositActor internal actor;

    function setUp() public {
        token = new RecursiveDepositToken();
        vault = new PortfolioCollateralVault(address(token));
        actor = new RecursiveDepositActor(token, address(vault), true);
        token.mint(address(actor), 200);
        address sponsor = address(0xCAFE);
        token.mint(sponsor, 300);
        vm.prank(sponsor);
        token.approve(address(vault), 300);
        vm.prank(sponsor);
        vault.deposit(300);
    }

    function testRecursiveDepositRevertsWithoutDoubleCredit() public {
        vm.expectRevert(PortfolioCollateralVault.UnsupportedTokenBehavior.selector);
        actor.depositWithCallback(100, false);
        assertEq(token.balanceOf(address(actor)), 200, "actor tokens moved");
        assertEq(token.balanceOf(address(vault)), 300, "sponsor custody changed");
        assertEq(vault.balanceOf(address(actor)), 0, "account gained credit");
        assertEq(vault.totalAccountedCollateral(), 300, "accounting inflated");
    }
}

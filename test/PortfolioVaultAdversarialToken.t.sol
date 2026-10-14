// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";

contract AdversarialVaultToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public outboundExtraDebit;
    bool public callbackEnabled;
    bool public callbackRejected;
    address public vault;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function configure(address vault_, uint256 extra, bool callback_) external {
        vault = vault_;
        outboundExtraDebit = extra;
        callbackEnabled = callback_;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        require(approved >= amount, "allowance");
        allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 debit = amount;
        if (msg.sender == vault) {
            if (callbackEnabled) {
                (bool ok,) = vault.call(
                    abi.encodeWithSignature("deposit(uint256)", uint256(1))
                );
                callbackRejected = !ok;
            }
            debit += outboundExtraDebit;
        }
        balanceOf[msg.sender] -= debit;
        balanceOf[to] += amount;
        return true;
    }
}

contract PortfolioVaultAdversarialTokenTest is TestBase {
    AdversarialVaultToken token;
    PortfolioCollateralVault vault;

    function setUp() public {
        token = new AdversarialVaultToken();
        vault = new PortfolioCollateralVault(address(token));
        token.configure(address(vault), 0, false);
        token.mint(address(this), 1_000);
        token.approve(address(vault), 1_000);
        vault.deposit(300);
    }

    function testStandaloneWithdrawalRejectsExtraTokenDebitAtomically() public {
        token.configure(address(vault), 1, false);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.withdraw, (uint256(100))));
        assertTrue(!ok, "excess token debit was accepted");
        assertEq(token.balanceOf(address(vault)), 300, "failed transfer spent tokens");
        assertEq(vault.totalAccountedCollateral(), 300, "failed transfer changed ledger");
        assertEq(vault.balanceOf(address(this)), 300, "failed transfer changed claim");
    }

    function testPortfolioControllerWithdrawalRejectsExtraDebitAtomically() public {
        vault.configureController(address(this));
        token.configure(address(vault), 1, false);
        (bool ok,) = address(vault).call(
            abi.encodeCall(vault.controllerWithdraw, (address(this), address(this), uint256(100)))
        );
        assertTrue(!ok, "extra-debit portfolio payout accepted");
        assertEq(token.balanceOf(address(vault)), 300, "portfolio payout drained vault");
        assertEq(vault.totalAccountedCollateral(), 300, "portfolio claims changed");
        assertEq(vault.portfolioWithdrawn(address(this)), 0, "withdrawal checkpoint changed");
    }

    function testRecursiveCallbackIsRejectedWithoutBlockingOrdinaryPayout() public {
        token.configure(address(vault), 0, true);
        vault.withdraw(100);
        assertTrue(token.callbackRejected(), "recursive custody callback succeeded");
        assertEq(token.balanceOf(address(vault)), 200, "custody payout incorrect");
        assertEq(vault.totalAccountedCollateral(), 200, "ledger payout incorrect");
    }

    function testExcessSweepRejectsUnexpectedExtraDebit() public {
        token.mint(address(vault), 50);
        token.configure(address(vault), 1, false);
        (bool ok,) = address(vault).call(
            abi.encodeCall(vault.sweepExcess, (address(this), uint256(50)))
        );
        assertTrue(!ok, "extra-debit excess sweep accepted");
        assertEq(token.balanceOf(address(vault)), 350, "failed excess sweep spent backing");
        assertEq(vault.totalAccountedCollateral(), 300, "failed excess sweep modified ledger");
    }
}

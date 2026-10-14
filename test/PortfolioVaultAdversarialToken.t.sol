// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";

contract AdversarialVaultToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public outboundExtraDebit;
    uint256 public recipientShortfall;
    bool public callbackEnabled;
    bool public callbackRejected;
    address public vault;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function configureRecipientShortfall(uint256 shortfall) external {
        recipientShortfall = shortfall;
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
        balanceOf[to] += amount - recipientShortfall;
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

    function testFuzz_OutgoingExtraDebitAlwaysRollsBack(uint96 amountSeed, uint8 extraSeed) public {
        uint256 amount = uint256(amountSeed) % 200 + 1;
        uint256 extra = uint256(extraSeed) % 20 + 1;
        token.configure(address(vault), extra, true);

        uint256 beforeCustody = token.balanceOf(address(vault));
        uint256 beforeLedger = vault.totalAccountedCollateral();
        (bool ok,) = address(vault).call(abi.encodeCall(vault.withdraw, (amount)));

        assertTrue(!ok, "extra-debit transfer succeeded");
        assertEq(token.balanceOf(address(vault)), beforeCustody, "reverted debit spent funds");
        assertEq(vault.totalAccountedCollateral(), beforeLedger, "reverted debit changed ledger");
        assertEq(vault.balanceOf(address(this)), beforeLedger, "reverted debit changed user claim");
    }

    function testFuzz_ControllerTransferMaintainsExactBacking(uint96 amountSeed) public {
        vault.configureController(address(this));
        uint256 amount = uint256(amountSeed) % 300 + 1;
        uint256 beforeCustody = token.balanceOf(address(vault));
        uint256 beforeLedger = vault.totalAccountedCollateral();

        vault.controllerWithdraw(address(this), address(this), amount);

        assertEq(token.balanceOf(address(vault)), beforeCustody - amount, "physical debit mismatch");
        assertEq(vault.totalAccountedCollateral(), beforeLedger - amount, "accounted debit mismatch");
        assertEq(vault.portfolioWithdrawn(address(this)), amount, "withdrawal claim mismatch");
    }

    function testFuzz_RecipientUndercreditRevertsWithoutBurningClaim(
        uint96 payoutSeed, uint8 shortfallSeed
    ) public {
        uint256 payout = uint256(payoutSeed) % 200 + 1;
        uint256 shortfall = uint256(shortfallSeed) % payout + 1;
        token.configureRecipientShortfall(shortfall);
        uint256 recipientBefore = token.balanceOf(address(this));

        (bool ok,) = address(vault).call(abi.encodeCall(vault.withdraw, (payout)));
        assertTrue(!ok, "taxed receipt silently consumed collateral claim");
        assertEq(token.balanceOf(address(this)), recipientBefore, "reverted payment credited recipient");
        assertEq(token.balanceOf(address(vault)), 300, "reverted payment debited custody");
        assertEq(vault.totalAccountedCollateral(), 300, "reverted payment changed ledger");
        assertEq(vault.balanceOf(address(this)), 300, "reverted payment reduced user claim");
    }

    function testFuzz_PortfolioUndercreditRevertsWithoutAdvancingWithdrawal(
        uint96 payoutSeed, uint8 shortfallSeed
    ) public {
        vault.configureController(address(this));
        uint256 payout = uint256(payoutSeed) % 200 + 1;
        uint256 shortfall = uint256(shortfallSeed) % payout + 1;
        token.configureRecipientShortfall(shortfall);

        (bool ok,) = address(vault).call(abi.encodeCall(
            vault.controllerWithdraw, (address(this), address(this), payout)
        ));
        assertTrue(!ok, "portfolio taxed receipt silently consumed collateral");
        assertEq(token.balanceOf(address(vault)), 300, "failed withdrawal spent custody");
        assertEq(vault.totalAccountedCollateral(), 300, "failed withdrawal changed accounting");
        assertEq(vault.portfolioWithdrawn(address(this)), 0, "failed withdrawal was checkpointed");
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

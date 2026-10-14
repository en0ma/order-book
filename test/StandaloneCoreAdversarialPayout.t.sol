// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {AdversarialVaultToken} from "./PortfolioVaultAdversarialToken.t.sol";

contract StandaloneCoreAdversarialPayoutTest is TestBase {
    AdversarialVaultToken internal token;
    OrderBookCore internal core;

    function setUp() public {
        token = new AdversarialVaultToken();
        core = new OrderBookCore(address(token), address(new MockMarkOracle(100)), 30, 1000, 0, 0);
        token.configure(address(core), 0, false);
        token.mint(address(this), 1_000);
        token.approve(address(core), 1_000);
        core.depositCollateral(400);
    }

    function testFuzz_StandaloneTokenRecipientShortfallRevertsAtomically(
        uint96 payoutSeed, uint8 shortfallSeed
    ) public {
        uint256 payout = uint256(payoutSeed) % 300 + 1;
        token.configureRecipientShortfall(uint256(shortfallSeed) % payout + 1);
        uint256 beforeTrader = token.balanceOf(address(this));
        (bool ok,) = address(core).call(
            abi.encodeCall(core.withdrawCollateral, (payout))
        );
        assertTrue(!ok, "short-credit withdrawal consumed collateral");
        assertEq(token.balanceOf(address(this)), beforeTrader, "failed withdrawal moved recipient");
        assertEq(token.balanceOf(address(core)), 400, "failed withdrawal spent custody");
        assertEq(core.accountEquity(address(this)), int256(400), "failed withdrawal changed equity");
    }

    function testFuzz_StandaloneExtraTokenDebitRevertsAtomically(
        uint96 payoutSeed, uint8 extraSeed
    ) public {
        uint256 payout = uint256(payoutSeed) % 300 + 1;
        token.configure(address(core), uint256(extraSeed) % 20 + 1, false);
        (bool ok,) = address(core).call(
            abi.encodeCall(core.withdrawCollateral, (payout))
        );
        assertTrue(!ok, "extra-debit withdrawal consumed collateral");
        assertEq(token.balanceOf(address(core)), 400, "failed payout spent custody");
        assertEq(core.accountEquity(address(this)), int256(400), "failed payout changed equity");
    }

    function testFuzz_StandaloneOrdinaryWithdrawalMaintainsExactBacking(uint96 seed) public {
        uint256 payout = uint256(seed) % 300 + 1;
        uint256 beforeRecipient = token.balanceOf(address(this));
        core.withdrawCollateral(payout);
        assertEq(token.balanceOf(address(this)), beforeRecipient + payout, "recipient underpaid");
        assertEq(token.balanceOf(address(core)), 400 - payout, "custody debit mismatch");
        assertEq(core.accountEquity(address(this)), int256(400 - payout), "equity mismatch");
    }
}

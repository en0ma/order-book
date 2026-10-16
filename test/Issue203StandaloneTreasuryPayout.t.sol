// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract Issue203StandaloneTreasuryPayoutTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);
    address internal constant TREASURY = address(0xFEED);
    MockERC20 internal token;
    OrderBookCore internal core;

    function setUp() public {
        token = new MockERC20();
        core = new OrderBookCore(address(token), address(new MockMarkOracle(100)), 30, 1000, 100, 0);
        token.mint(MAKER, 50000);
        token.mint(TAKER, 50000);
        vm.prank(MAKER);
        token.approve(address(core), type(uint256).max);
        vm.prank(MAKER);
        core.depositCollateral(50000);
        vm.prank(TAKER);
        token.approve(address(core), type(uint256).max);
        vm.prank(TAKER);
        core.depositCollateral(50000);
    }

    function _settleRoundTrip() internal {
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);

        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Ask, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Bid, 100);
    }

    function test_OnlyOwnerCanConfigureImmutableNonzeroTreasury() public {
        vm.prank(MAKER);
        (bool unauthorized,) = address(core).call(
            abi.encodeCall(core.configureTreasuryRecipient, (TREASURY))
        );
        assertTrue(!unauthorized, "unauthorized user configured protocol treasury");

        (bool invalid,) = address(core).call(
            abi.encodeCall(core.configureTreasuryRecipient, (address(0)))
        );
        assertTrue(!invalid, "zero treasury authorized");
        core.configureTreasuryRecipient(TREASURY);
        (bool replaced,) = address(core).call(
            abi.encodeCall(core.configureTreasuryRecipient, (MAKER))
        );
        assertTrue(!replaced, "treasury authorization was mutable after approval");
        assertTrue(core.treasuryRecipient() == TREASURY, "wrong authorized recipient");
    }

    function test_PartialAndFullPayoutArePhysicallyBackedAfterSettlement() public {
        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        _settleRoundTrip();

        (uint256 available, uint256 claims, uint256 liabilities) =
            core.claimantRegistry().standaloneFeeCapacity();
        assertEq(available, 200, "earned fees were not backed by standalone custody");
        assertEq(claims, 99800, "signed settlements did not conserve claimant cash");
        assertEq(liabilities, 99800, "incorrect protected liability floor");

        vm.prank(TAKER);
        (bool unauthorized,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (uint256(1)))
        );
        assertTrue(!unauthorized, "taker withdrew treasury funds");

        core.withdrawProtocolFees(75);
        assertEq(token.balanceOf(TREASURY), 75, "partial treasury transfer mismatch");
        assertEq(core.protocolFeesAccrued(), 125, "partial fee debit incorrect");
        assertEq(token.balanceOf(address(core)), 99925, "partial custody debit incorrect");

        core.setFeeDistributionEnabled(false);
        (bool paused,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (uint256(1)))
        );
        assertTrue(!paused, "paused fee distribution transferred tokens");
        assertEq(core.protocolFeesAccrued(), 125, "pause changed earned fee ledger");
        core.setFeeDistributionEnabled(true);

        core.withdrawProtocolFees(125);
        assertEq(token.balanceOf(TREASURY), 200, "full treasury transfer mismatch");
        assertEq(core.protocolFeesAccrued(), 0, "repeated fee payout possible");
        assertEq(token.balanceOf(address(core)), 99800, "remaining backing mismatch");

        (bool replay,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (uint256(1)))
        );
        assertTrue(!replay, "zero-fee payout replay succeeded");
    }

    function testFuzz_RejectsUnprovedAndOverCapDistributions(uint16 extra) public {
        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        _settleRoundTrip();
        uint256 requested = 201 + uint256(extra);
        (bool paid,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (requested))
        );
        assertTrue(!paid, "withdrawal exceeded global on-chain surplus");
        assertEq(core.protocolFeesAccrued(), 200, "failed payout debited fee ledger");
        assertEq(token.balanceOf(TREASURY), 0, "failed payout transferred ERC20");
        assertEq(token.balanceOf(address(core)), 100000, "failed payout damaged custody");
    }

    function test_PendingMakerObligationsPreventPayoutEvenWithDonations() public {
        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        token.mint(address(core), 1000000);

        (bool paid,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (uint256(1)))
        );
        assertTrue(!paid, "unsettled maker position authorized fee extraction");
        assertEq(token.balanceOf(TREASURY), 0, "unsettled fee moved to treasury");
    }

    function test_NonzeroFeeCannotLeaveInsuranceReserveUnderbacked() public {
        core.configureTreasuryRecipient(TREASURY);
        _settleRoundTrip();
        token.mint(address(this), 250);
        token.approve(address(core), 250);
        core.fundInsurance(250);

        core.withdrawProtocolFees(200);
        assertEq(core.insuranceReserves(), 250, "fee payment consumed insurance reserve");
        assertEq(token.balanceOf(address(core)), 100050,
            "positive account claims and insurance not physically backed");
    }
    function test_DistributionRemainsDisabledOnNewDeploymentEvenWhenFullyBacked() public {
        _settleRoundTrip();
        core.configureTreasuryRecipient(TREASURY);
        assertTrue(!core.feeDistributionEnabled(), "treasury enabled by deployment");
        (bool paid,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (uint256(1)))
        );
        assertTrue(!paid, "fee distribution enabled without independent activation");
        assertEq(token.balanceOf(TREASURY), 0, "inactive treasury received tokens");
        assertEq(core.protocolFeesAccrued(), 200, "inactive fee call altered accounting");
    }

    function test_ExistingLegitimateLiquidationRewardAndTreasuryShareOneFeeLedger() public {
        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        _settleRoundTrip();

        AdvancedOrderModule gateway =
            new AdvancedOrderModule(address(core), address(new MockMarkOracle(100)));
        core.configureAdvancedModule(address(gateway));
        address liquidator = address(0xCAFE);

        vm.prank(address(gateway));
        uint256 paid = core.modulePayLiquidationReward(liquidator, 30);
        assertEq(paid, 30, "existing valid liquidation reward was blocked");
        assertEq(token.balanceOf(liquidator), 30, "liquidation reward underpaid");
        assertEq(core.protocolFeesAccrued(), 170, "reward did not debit fee reserve");

        core.withdrawProtocolFees(170);
        assertEq(token.balanceOf(TREASURY), 170, "treasury double spent reward");
        assertEq(core.protocolFeesAccrued(), 0, "rewards and treasury fees were counted twice");
        assertEq(token.balanceOf(address(core)), 99800, "customer claims lost their backing");
    }

    function test_EmergencyRiskPauseBlocksFeeDistributionWithoutDebitingLedger() public {
        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        _settleRoundTrip();
        core.setRiskIncreasePaused(true);
        (bool paid,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (uint256(1)))
        );
        assertTrue(!paid, "treasury paid while risk circuit breaker was active");
        assertEq(core.protocolFeesAccrued(), 200, "emergency pause consumed protocol fees");
        assertEq(token.balanceOf(TREASURY), 0, "emergency pause leaked ERC20");
    }

    function testFuzz_BothFundingSignsAfterCompleteSettlementProtectPhysicalClaims(bool positive) public {
        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);

        core.setFundingIndex(positive ? int128(1e18) : -int128(1e18));
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Ask, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Bid, 100);

        (uint256 capacity, uint256 claims, uint256 protected) =
            core.claimantRegistry().standaloneFeeCapacity();
        assertTrue(claims <= protected, "funding caused negative reserve calculation");
        assertTrue(token.balanceOf(address(core)) >= protected,
            "fully settled funding consumed physical custody");
        assertTrue(capacity <= core.protocolFeesAccrued(),
            "signed funding minted protocol-owned tokens");
        // A fully settled but undercollateralized account set may still
        // conservatively have zero fee capacity; zero is not a valid payout.
        if (capacity != 0) core.withdrawProtocolFees(capacity);
        assertEq(token.balanceOf(TREASURY), capacity,
            "funded treasury transfer was not exact");
        assertTrue(token.balanceOf(address(core)) >= protected,
            "treasury payout spent settlement funding claims");
    }

    function test_ExhaustiveRosterRequirementRejectsUnsupportedClaimantCardinality() public {
        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        _settleRoundTrip();
        for (uint256 i; i < 63; ++i) {
            address account = address(uint160(i + 1000));
            token.mint(account, 1);
            vm.prank(account);
            token.approve(address(core), 1);
            vm.prank(account);
            core.depositCollateral(1);
        }

        assertEq(core.claimantRegistry().count(), 65, "funded account roster truncated");
        uint256 custodyBefore = token.balanceOf(address(core));
        (bool paid,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (uint256(1)))
        );
        assertTrue(!paid, "payout accepted an incomplete bounded claimant proof");
        assertEq(core.protocolFeesAccrued(), 200, "invalid proof changed fee reserve");
        assertEq(token.balanceOf(TREASURY), 0, "unsupported claimant proof sent fees");
        assertEq(token.balanceOf(address(core)), custodyBefore,
            "rejected proof altered physical collateral");
    }

    function test_QuoteTopUpsCannotHideLazyFundingOrRebateLiabilityFromPayoutProof() public {
        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 40);
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 60);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);

        (bool premature,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (uint256(1)))
        );
        assertTrue(!premature, "quote top-up lost unsettled maker claim");
        assertEq(core.protocolFeesAccrued(), 100, "early quote fill fee incorrect");
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);

        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Ask, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Bid, 100);

        core.withdrawProtocolFees(200);
        assertEq(core.protocolFeesAccrued(), 0, "completed maker quote duplicated fees");
        assertEq(token.balanceOf(TREASURY), 200, "reconciled fee payout incorrect");
        assertEq(token.balanceOf(address(core)), 99800, "maker top-up spent customer claims");
    }

    function test_ExtractedPayoutModuleCannotBypassCoreOwnerOrGuard() public {
        _settleRoundTrip();
        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
        uint256 beforeFees = core.protocolFeesAccrued();

        (bool viaModule,) = address(core.standaloneFeePayoutModule()).call(
            abi.encodeWithSignature("execute(uint256)", uint256(1))
        );
        assertTrue(!viaModule, "direct helper call bypassed the Core authorization gate");

        (bool directDebit,) = address(core).call(
            abi.encodeCall(core.moduleExecuteTreasuryFeePayout, (uint256(1)))
        );
        assertTrue(!directDebit, "caller forged self-only fee debit");
        assertEq(core.protocolFeesAccrued(), beforeFees, "unauthorized path debited fees");
        assertEq(token.balanceOf(TREASURY), 0, "unauthorized path transferred collateral");
    }

    function test_ExactTransferModuleDirectCallCannotSpendCoreCustody() public {
        _settleRoundTrip();
        uint256 custodyBefore = token.balanceOf(address(core));
        (bool ok,) = address(core.exactCollateralTransferModule()).call(
            abi.encodeWithSignature("transferExact(address,uint256)", TREASURY, uint256(1))
        );
        assertTrue(!ok, "helper direct call misappropriated Core ERC20");
        assertEq(token.balanceOf(address(core)), custodyBefore,
            "helper directly debited nondelegating Core");
        assertEq(token.balanceOf(TREASURY), 0, "helper directly credited treasury");
    }

    function test_InvalidCustodialTreasuryAddressesCannotBeLockedIn() public {
        (bool self,) = address(core).call(
            abi.encodeCall(core.configureTreasuryRecipient, (address(core)))
        );
        assertTrue(!self, "self-treasury would trap permanently configured recipient");
        (bool tokenAddress,) = address(core).call(
            abi.encodeCall(core.configureTreasuryRecipient, (address(token)))
        );
        assertTrue(!tokenAddress, "ERC20 contract erroneously authorized as recipient");
        assertTrue(core.treasuryRecipient() == address(0),
            "invalid recipient irreversibly configured treasury");
        core.configureTreasuryRecipient(TREASURY);
        assertTrue(core.treasuryRecipient() == TREASURY, "valid treasury rejected");
    }

}

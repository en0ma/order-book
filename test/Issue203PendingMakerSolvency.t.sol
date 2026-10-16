// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @notice Regression showing why a cash/equity-only fee bound is unsafe
/// before makers settle their execution positions and funding checkpoints.
contract Issue203PendingMakerSolvencyTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);
    MockERC20 internal token;
    MockMarkOracle internal oracle;
    OrderBookCore internal core;

    function setUp() public {
        token = new MockERC20();
        oracle = new MockMarkOracle(100);
        core = new OrderBookCore(address(token), address(oracle), 30, 1000, 100, 50);
        token.mint(MAKER, 50000);
        token.mint(TAKER, 50000);
        vm.prank(MAKER);
        token.approve(address(core), 50000);
        vm.prank(MAKER);
        core.depositCollateral(50000);
        vm.prank(TAKER);
        token.approve(address(core), 50000);
        vm.prank(TAKER);
        core.depositCollateral(50000);
    }

    function testFuzz_MakerPendingExecutionAndFundingInvalidateNaiveSurplus(bool positiveFunding) public {
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        assertEq(core.claimantRegistry().count(), 2, "on-chain claimant discovery incomplete");
        assertEq(core.protocolFeesAccrued(), 50, "net protocol fee mismatch");

        // Taker realizes the open long immediately; the resting maker's
        // short and rebate remain lazily attributed until settlement.
        oracle.setMarkTick(120);
        core.setFundingIndex(positiveFunding ? int128(1e18) : -int128(1e18));
        uint256 custody = token.balanceOf(address(core));
        assertEq(custody, 100000, "trade or funding transferred custody");

        int256 naiveClaimsBefore =
            core.accountEquity(MAKER) + core.accountEquity(TAKER)
                + int256(core.protocolFeesAccrued());
        assertTrue(naiveClaimsBefore > int256(custody),
            "naive settled-account sum unexpectedly accounts for lazy maker losses");

        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);

        int256 markedClaimsAfter =
            core.accountEquity(MAKER) + core.accountEquity(TAKER)
                + int256(core.protocolFeesAccrued());
        assertEq(markedClaimsAfter, int256(custody),
            "post-settlement maker/position/funding claims fail conservation");
        assertEq(token.balanceOf(address(core)), custody, "settlement transferred custody");
    }
    function test_GrossPendingMakerRiskCannotCancelBetweenBothOrderSides() public {
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 40);
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 40);

        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Ask, 80, 40, IOrderBookCore.FillPolicy.IOC);

        assertEq(core.claimantRegistry().pendingMakerUnattributedLots(), 80,
            "opposite-side pending lots were wrongly netted");
        assertEq(core.claimantRegistry().pendingPriceLevelCount(), 2,
            "opposite-side fills shared an invalid signed price bucket");

        oracle.setMarkTick(120);
        (uint256 capacity, uint256 claims, uint256 protected) =
            core.claimantRegistry().conservativeRewardCapacity();
        assertTrue(protected >= claims + core.pendingMakerRebateReserve(),
            "pending-maker liabilities cancelled against unrelated losses");
        assertTrue(capacity <= core.protocolFeesAccrued(),
            "opposing maker fills manufactured protocol fees");

        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Bid, 80);
        assertEq(core.claimantRegistry().pendingMakerUnattributedLots(), 0,
            "maker attribution did not consume all execution exposures");
        assertEq(core.claimantRegistry().pendingPriceLevelCount(), 0,
            "stale pending execution-price buckets remained after settlement");
    }

    function test_ClosedGenerationAndMakerTopupConsumeAllGrossPendingBuckets() public {
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 40);
        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 60);
        vm.prank(TAKER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        assertEq(core.claimantRegistry().pendingMakerUnattributedLots(), 100,
            "maker top-up lost attributed fill inventory");
        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);
        assertEq(core.claimantRegistry().pendingMakerUnattributedLots(), 0,
            "closed-generation maker accounting did not clear");
        assertEq(core.claimantRegistry().pendingPriceLevelCount(), 0,
            "closed generation has live positive maker payout risk");
    }

}

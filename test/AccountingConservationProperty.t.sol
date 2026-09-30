// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract AccountingConservationPropertyTest is TestBase {
    OrderBookCoreHarness internal core;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant TAKER = address(0x7A6E2);

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core =
            new OrderBookCoreHarness(address(token), address(oracle), 40, 1_000, 10, 5);

        core.configureAccountingUnitScale(1_000);

        _fund(ALICE, 10_000_000);
        _fund(BOB, 10_000_000);
        _fund(CAROL, 10_000_000);
        _fund(TAKER, 10_000_000);
    }

    function testFuzz_InternalClaimsNeverExceedTokenCustodyAfterSettlement(
        uint256 aliceSeed,
        uint256 bobSeed,
        uint256 carolSeed,
        uint256 fillSeed
    ) public {
        uint96 aliceLots = boundNonZero(aliceSeed, 700);
        uint96 bobLots = boundNonZero(bobSeed, 700);
        uint96 carolLots = boundNonZero(carolSeed, 700);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, aliceLots);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, bobLots);
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, carolLots);

        uint256 totalLots =
            uint256(aliceLots) + uint256(bobLots) + uint256(carolLots);
        uint256 maxSafeTakerLots = totalLots < 700 ? totalLots : 700;
        uint96 requested = uint96((fillSeed % maxSafeTakerLots) + 1);

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            requested,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);
        vm.prank(BOB);
        core.settle(IOrderBookCore.Side.Ask, 105);
        vm.prank(CAROL);
        core.settle(IOrderBookCore.Side.Ask, 105);

        int256 userClaims =
            _cashClaim(ALICE) + _cashClaim(BOB) + _cashClaim(CAROL)
                + _cashClaim(TAKER);
        assertTrue(userClaims >= 0, "aggregate user cash claim negative");

        uint256 protocolClaims =
            core.protocolFeesAccrued() + core.insuranceReserves();
        uint256 totalClaims = uint256(userClaims) + protocolClaims;
        uint256 custody = token.balanceOf(address(core));

        assertTrue(totalClaims <= custody, "internal claims exceed token custody");
    }

    function _cashClaim(address account) internal view returns (int256 claim) {
        (uint256 collateral, int256 trading, int256 funding,,) =
            core.accountingStateTest(account);
        claim = int256(collateral) + trading + funding;
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }
}

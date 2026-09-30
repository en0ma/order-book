// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract FeeAccountingPropertyTest is TestBase {
    OrderBookCore internal core;
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
            new OrderBookCore(address(token), address(oracle), 40, 1_000, 10, 5);

        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
        _fund(TAKER);
    }

    function testFuzz_MakerRebateRoundingNeverExceedsReservedRebate(
        uint256 aliceSeed,
        uint256 bobSeed,
        uint256 carolSeed,
        uint256 fillSeed
    ) public {
        uint96 aliceLots = boundNonZero(aliceSeed, 10_000);
        uint96 bobLots = boundNonZero(bobSeed, 10_000);
        uint96 carolLots = boundNonZero(carolSeed, 10_000);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, aliceLots);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, bobLots);
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, carolLots);

        uint256 totalLots =
            uint256(aliceLots) + uint256(bobLots) + uint256(carolLots);
        uint96 requested = uint96((fillSeed % totalLots) + 1);

        vm.prank(TAKER);
        uint96 filled = core.take(
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

        uint256 executedNotional = uint256(filled) * 105;
        uint256 takerFee = executedNotional * 10 / 10_000;
        uint256 reservedMakerRebate = executedNotional * 5 / 10_000;

        uint256 creditedRebate =
            _makerRebate(ALICE) + _makerRebate(BOB) + _makerRebate(CAROL);

        assertEq(
            core.protocolFeesAccrued(),
            takerFee - reservedMakerRebate,
            "protocol net reserve mismatch"
        );
        assertTrue(
            creditedRebate <= reservedMakerRebate,
            "maker rebates exceeded reserved rebate"
        );
        assertTrue(
            core.protocolFeesAccrued() + creditedRebate <= takerFee,
            "fee accounting over-distributed taker fee"
        );
    }

    function _makerRebate(address maker) internal view returns (uint256 rebate) {
        (int80 position,,) = core.accountRisk(maker);
        uint256 filledLots = uint256(uint80(-position));

        // At execution tick 105 with mark 100, maker equity before rebate
        // increases by 5 per filled lot from marked trading PnL.
        int256 baselineEquity =
            int256(10_000_000 + filledLots * 5);
        int256 equity = core.accountEquity(maker);

        assertTrue(equity >= baselineEquity, "maker equity below fee-free baseline");
        rebate = uint256(equity - baselineEquity);
    }

    function _fund(address account) internal {
        token.mint(account, 10_000_000);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(10_000_000);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract MakerAttributionPropertyTest is TestBase {
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
        core = new OrderBookCore(address(token), address(oracle), 40, 1_000);

        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
        _fund(TAKER);
    }

    function testFuzz_LazyMakerAttributionNeverOverCreditsAcrossLateJoins(
        uint256 aSeed,
        uint256 bSeed,
        uint256 cSeed,
        uint256 firstFillSeed,
        uint256 secondFillSeed
    ) public {
        uint96 aliceLots = boundNonZero(aSeed, 1_000);
        uint96 bobLots = boundNonZero(bSeed, 1_000);
        uint96 carolLots = boundNonZero(cSeed, 1_000);

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, aliceLots);

        uint96 firstFill = uint96(firstFillSeed % (uint256(aliceLots) + 1));
        if (firstFill != 0) {
            vm.prank(TAKER);
            core.take(
                IOrderBookCore.Side.Bid,
                105,
                firstFill,
                IOrderBookCore.FillPolicy.IOC
            );
        }

        // BOB and CAROL join after the first fill, exercising share minting at
        // a non-initial pool exchange rate whenever Alice still has liquidity.
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, bobLots);
        vm.prank(CAROL);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, carolLots);

        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Ask, 105);
        uint96 secondFill =
            uint96(secondFillSeed % (uint256(remaining) + 1));

        if (secondFill != 0) {
            vm.prank(TAKER);
            core.take(
                IOrderBookCore.Side.Bid,
                105,
                secondFill,
                IOrderBookCore.FillPolicy.IOC
            );
        }

        vm.prank(ALICE);
        core.settle(IOrderBookCore.Side.Ask, 105);
        vm.prank(BOB);
        core.settle(IOrderBookCore.Side.Ask, 105);
        vm.prank(CAROL);
        core.settle(IOrderBookCore.Side.Ask, 105);

        int256 takerPosition = int256(_position(TAKER));
        int256 makerPosition =
            int256(_position(ALICE)) + int256(_position(BOB)) + int256(_position(CAROL));

        int256 roundingDebt = makerPosition + takerPosition;

        assertTrue(
            roundingDebt >= 0,
            "lazy maker attribution exceeded executed taker lots"
        );
        assertTrue(
            roundingDebt <= 2,
            "three-maker rounding debt exceeded makers-1 bound"
        );
        assertEq(
            takerPosition,
            int256(uint256(firstFill) + uint256(secondFill)),
            "taker position != executed lots"
        );
    }

    function _position(address account) internal view returns (int80 position) {
        (position,,) = core.accountRisk(account);
    }

    function _fund(address account) internal {
        token.mint(account, 10_000_000);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(10_000_000);
    }
}

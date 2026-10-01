// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

/// @notice Adversarial sequence tests over the deployable contracts.
/// @dev Expected operation reverts are tolerated; canonical invariants are checked
///      after every attempted state transition.
contract DeployableStateMachineTest is TestBase {
    OrderBookCoreHarness internal core;
    AdvancedOrderModule internal advanced;
    MarketMakerModule internal marketMaker;
    LiquidationModule internal liquidation;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DAVE = address(0xDA7E);
    address internal constant FINALIZER = address(0xF1A1);

    uint16[3] internal BID_TICKS = [uint16(94), uint16(95), uint16(96)];
    uint16[3] internal ASK_TICKS = [uint16(104), uint16(105), uint16(106)];

    uint32[6] internal lastGeneration;

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCoreHarness(address(token), address(oracle), 40, 1_000, 10, 5);
        advanced = new AdvancedOrderModule(address(core), address(oracle));
        marketMaker = new MarketMakerModule(address(core), address(advanced));
        liquidation = new LiquidationModule(address(core), address(advanced), 500);

        core.configureAdvancedModule(address(advanced));
        advanced.configureMarketMakerModule(address(marketMaker));
        advanced.configureLiquidationModule(address(liquidation));

        _fund(ALICE, 10_000_000);
        _fund(BOB, 10_000_000);
        _fund(CAROL, 10_000_000);
        _fund(DAVE, 10_000_000);
        _fund(FINALIZER, 1_000_000_000);

        _checkInvariants();
    }

    function testFuzz_AdversarialShortSequence(uint256 seed) public {
        _runSequence(seed, 12);
    }

    function testAdversarialLongSequenceCorpus() public {
        // Keep this deterministic corpus below Forge's single-test gas ceiling.
        // The fuzz test above already runs 5,000 independently seeded sequences.
        for (uint256 seed = 1; seed <= 12; ++seed) {
            _runSequence(uint256(keccak256(abi.encode(seed))), 32);
        }
    }

    function _runSequence(uint256 seed, uint256 steps) internal {
        uint256 randomness = seed;

        for (uint256 step; step < steps; ++step) {
            randomness = uint256(keccak256(abi.encode(randomness, step)));
            _step(randomness);
            _checkInvariants();
        }

        _drainTrackedBook();
        _settleAllTrackedState();
        _checkInvariants();
        _checkCustodyBacking();
    }

    function _step(uint256 r) internal {
        uint256 op = r % 10;
        address actor = _actor((r >> 8) % 4);
        IOrderBookCore.Side side =
            ((r >> 16) & 1) == 0 ? IOrderBookCore.Side.Bid : IOrderBookCore.Side.Ask;
        uint16 tick = _tick(side, (r >> 24) % 3);
        uint96 lots = uint96(((r >> 32) % 80) + 1);

        if (op == 0 || op == 1) {
            _managedTarget(actor, side, tick, op == 0 ? lots : uint96(0));
        } else if (op == 2) {
            _directAdd(actor, side, tick, lots);
        } else if (op == 3) {
            _directRemove(actor, side, tick, r);
        } else if (op == 4) {
            _take(actor, side, lots);
        } else if (op == 5) {
            _settle(actor, side, tick);
        } else if (op == 6) {
            _setFunding(r);
        } else if (op == 7) {
            _moveOracle(r);
        } else if (op == 8) {
            _managedTwoLevel(actor, side, r);
        } else {
            _take(actor, side, uint96((lots / 2) + 1));
            _settle(_actor((r >> 48) % 4), side, tick);
        }
    }

    function _managedTarget(
        address actor,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots
    ) internal {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] =
            MarketMakerModule.QuoteUpdate({side: side, tick: tick, lots: lots});

        vm.prank(actor);
        address(marketMaker).call(
            abi.encodeCall(marketMaker.batchReplaceQuotes, (updates))
        );
    }

    function _managedTwoLevel(address actor, IOrderBookCore.Side side, uint256 r)
        internal
    {
        uint256 firstIndex = (r >> 56) % 2;
        uint16 first = _tick(side, firstIndex);
        uint16 second = _tick(side, firstIndex + 1);

        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](2);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: side,
            tick: first,
            lots: uint96(((r >> 64) % 60) + 1)
        });
        updates[1] = MarketMakerModule.QuoteUpdate({
            side: side,
            tick: second,
            lots: uint96(((r >> 80) % 60) + 1)
        });

        vm.prank(actor);
        address(marketMaker).call(
            abi.encodeCall(marketMaker.batchReplaceQuotes, (updates))
        );
    }

    function _directAdd(
        address actor,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots
    ) internal {
        vm.prank(actor);
        address(core).call(abi.encodeCall(core.addLiquidity, (side, tick, lots)));
    }

    function _directRemove(
        address actor,
        IOrderBookCore.Side side,
        uint16 tick,
        uint256 r
    ) internal {
        (uint128 shares,,) = core.quotes(actor, side, tick);
        if (shares == 0) return;

        uint128 burn = uint128((r % shares) + 1);
        vm.prank(actor);
        address(core).call(abi.encodeCall(core.removeShares, (side, tick, burn)));
    }

    function _take(address actor, IOrderBookCore.Side takerSide, uint96 lots) internal {
        uint16 limitTick =
            takerSide == IOrderBookCore.Side.Bid ? uint16(106) : uint16(94);

        vm.prank(actor);
        address(core).call(
            abi.encodeCall(
                core.take,
                (
                    takerSide,
                    limitTick,
                    lots,
                    IOrderBookCore.FillPolicy.IOC
                )
            )
        );
    }

    function _settle(address actor, IOrderBookCore.Side side, uint16 tick) internal {
        vm.prank(actor);
        address(core).call(abi.encodeCall(core.settle, (side, tick)));
    }

    function _setFunding(uint256 r) internal {
        int256 signed = int256(r % 2_001) - 1_000;
        core.setFundingIndex(int128(signed * 1e14));
    }

    function _moveOracle(uint256 r) internal {
        // Keep all tracked ticks inside the 40-tick execution band.
        oracle.record(uint16(98 + (r % 5)));
    }

    function _checkInvariants() internal {
        address[4] memory actors = [ALICE, BOB, CAROL, DAVE];

        for (uint256 a; a < actors.length; ++a) {
            (int80 settled, int80 minPosition, int80 maxPosition) =
                core.accountRisk(actors[a]);
            assertTrue(minPosition <= settled, "risk min above settled");
            assertTrue(settled <= maxPosition, "risk settled above max");

            uint256 liveQuotes;
            for (uint256 i; i < 3; ++i) {
                if (_quoteExists(actors[a], IOrderBookCore.Side.Bid, BID_TICKS[i])) {
                    ++liveQuotes;
                }
                if (_quoteExists(actors[a], IOrderBookCore.Side.Ask, ASK_TICKS[i])) {
                    ++liveQuotes;
                }
            }

            assertEq(
                uint256(core.activeQuoteCount(actors[a])),
                liveQuotes,
                "active quote count drift"
            );

            (, uint256 reserved) = core.marginStateTest(actors[a]);
            assertTrue(
                core.accountEquity(actors[a]) >= int256(reserved),
                "reserved margin exceeds account equity"
            );
        }

        for (uint256 i; i < 3; ++i) {
            _checkPool(IOrderBookCore.Side.Bid, BID_TICKS[i], i, actors);
            _checkPool(IOrderBookCore.Side.Ask, ASK_TICKS[i], i + 3, actors);
        }

    }

    function _drainTrackedBook() internal {
        uint96 askLots;
        uint96 bidLots;

        for (uint256 i; i < 3; ++i) {
            (, uint96 bidRemaining,) =
                core.pools(IOrderBookCore.Side.Bid, BID_TICKS[i]);
            (, uint96 askRemaining,) =
                core.pools(IOrderBookCore.Side.Ask, ASK_TICKS[i]);

            bidLots += bidRemaining;
            askLots += askRemaining;
        }

        if (askLots != 0) {
            vm.prank(FINALIZER);
            core.take(
                IOrderBookCore.Side.Bid,
                ASK_TICKS[2],
                askLots,
                IOrderBookCore.FillPolicy.IOC
            );
        }

        if (bidLots != 0) {
            vm.prank(FINALIZER);
            core.take(
                IOrderBookCore.Side.Ask,
                BID_TICKS[0],
                bidLots,
                IOrderBookCore.FillPolicy.IOC
            );
        }
    }

    function _settleAllTrackedState() internal {
        address[5] memory actors = [ALICE, BOB, CAROL, DAVE, FINALIZER];

        for (uint256 a; a < actors.length; ++a) {
            for (uint256 i; i < 3; ++i) {
                vm.prank(actors[a]);
                core.settle(IOrderBookCore.Side.Bid, BID_TICKS[i]);

                vm.prank(actors[a]);
                core.settle(IOrderBookCore.Side.Ask, ASK_TICKS[i]);
            }
        }
    }

    function _checkCustodyBacking() internal view {
        address[5] memory actors = [ALICE, BOB, CAROL, DAVE, FINALIZER];
        int256 userClaims;

        for (uint256 a; a < actors.length; ++a) {
            userClaims += _cashClaim(actors[a]);
        }

        int256 internalClaims =
            userClaims + int256(core.protocolFeesAccrued())
                + int256(core.insuranceReserves());

        assertTrue(internalClaims >= 0, "aggregate internal claims negative");
        assertTrue(
            uint256(internalClaims) <= token.balanceOf(address(core)),
            "fee/rebate accounting exceeded token custody"
        );
    }

    function _cashClaim(address account) internal view returns (int256) {
        (uint256 collateral, int256 trading, int256 funding,,) =
            core.accountingStateTest(account);
        return int256(collateral) + trading + funding;
    }

    function _checkPool(
        IOrderBookCore.Side side,
        uint16 tick,
        uint256 generationSlot,
        address[4] memory actors
    ) internal {
        (uint128 totalShares, uint96 remainingLots, uint32 generation) =
            core.pools(side, tick);

        assertTrue(
            (totalShares == 0) == (remainingLots == 0),
            "pool shares/lots emptiness mismatch"
        );
        assertTrue(
            generation >= lastGeneration[generationSlot],
            "pool generation regressed"
        );
        lastGeneration[generationSlot] = generation;

        uint256 currentShares;
        for (uint256 a; a < actors.length; ++a) {
            (uint128 shares,, uint32 quoteGeneration) =
                core.quotes(actors[a], side, tick);

            if (shares == 0) continue;

            assertTrue(
                quoteGeneration <= generation,
                "quote generation exceeds pool generation"
            );

            if (quoteGeneration == generation) {
                currentShares += shares;
                assertTrue(shares <= totalShares, "maker shares exceed pool shares");
            }
        }

        assertEq(currentShares, uint256(totalShares), "current maker shares != pool shares");
    }

    function _quoteExists(address actor, IOrderBookCore.Side side, uint16 tick)
        internal
        view
        returns (bool)
    {
        (uint128 shares,,) = core.quotes(actor, side, tick);
        return shares != 0;
    }

    function _tick(IOrderBookCore.Side side, uint256 index)
        internal
        view
        returns (uint16)
    {
        return side == IOrderBookCore.Side.Bid
            ? BID_TICKS[index]
            : ASK_TICKS[index];
    }

    function _actor(uint256 index) internal pure returns (address) {
        if (index == 0) return ALICE;
        if (index == 1) return BOB;
        if (index == 2) return CAROL;
        return DAVE;
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }
}

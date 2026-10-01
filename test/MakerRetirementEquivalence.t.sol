// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract LiquidationRetirementCaller {
    AdvancedOrderModule internal immutable advanced;

    constructor(AdvancedOrderModule advanced_) {
        advanced = advanced_;
    }

    function forceCancel(
        address account,
        IOrderBookCore.Side side,
        uint16 tick
    ) external returns (uint96 removedLots) {
        removedLots = advanced.liquidationForceCancelQuote(account, side, tick);
    }
}

/// @notice Cross-entry-point property tests for canonical maker retirement semantics.
/// @dev All retirement modes must converge on the same core economic state.
contract MakerRetirementEquivalenceTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant NEIGHBOR = address(0xB0B);
    address internal constant TAKER = address(0xCA401);

    uint16 internal constant TICK = 10_000;

    struct Snapshot {
        int80 settled;
        int80 minPosition;
        int80 maxPosition;
        int256 trading;
        int256 funding;
        uint256 reserved;
        uint256 protocolFees;
        uint96 poolRemaining;
        uint128 quoteShares;
        uint96 quoteClaim;
        uint32 activeQuotes;
        int256 aggregateEquity;
    }

    function testFuzz_RetirementEntryPointsPreserveEconomicAttribution(
        uint256 makerSeed,
        uint256 neighborSeed,
        uint256 fillSeed,
        uint256 fundingSeed
    ) public {
        uint96 makerLots = boundNonZero(makerSeed, 120);
        uint96 neighborLots = boundNonZero(neighborSeed, 120);
        uint96 totalLots = makerLots + neighborLots;
        uint96 fillLots = uint96((fillSeed % (uint256(totalLots) - 1)) + 1);
        int128 fundingIndex =
            int128((int256(fundingSeed % 17) - 8) * 1e18);

        Snapshot memory direct =
            _runScenario(0, makerLots, neighborLots, fillLots, fundingIndex);
        Snapshot memory managed =
            _runScenario(1, makerLots, neighborLots, fillLots, fundingIndex);
        Snapshot memory forced =
            _runScenario(2, makerLots, neighborLots, fillLots, fundingIndex);

        _assertEquivalent(direct, managed, "managed retirement diverged");
        _assertEquivalent(direct, forced, "force-cancel retirement diverged");
    }

    function testRoundingBoundaryRetirementModesCrystallizeSameFill() public {
        Snapshot memory direct = _runScenario(0, 1, 2, 1, int128(2e18));
        Snapshot memory managed = _runScenario(1, 1, 2, 1, int128(2e18));
        Snapshot memory forced = _runScenario(2, 1, 2, 1, int128(2e18));

        _assertEquivalent(direct, managed, "managed rounding retirement diverged");
        _assertEquivalent(direct, forced, "force-cancel rounding retirement diverged");

        assertEq(int256(direct.settled), -1, "burn-attributed maker fill missing");
        assertEq(int256(direct.minPosition), -1, "maker min risk mismatch");
        assertEq(int256(direct.maxPosition), -1, "maker max risk mismatch");
        assertEq(direct.quoteShares, 0, "retired maker shares remain");
        assertEq(direct.quoteClaim, 0, "retired maker claim remains");
    }

    function testFuzz_ClosedGenerationLazySettlementMatchesImmediateMaterialization(
        uint256 lotsSeed,
        uint256 fundingSeed
    ) public {
        uint96 lots = boundNonZero(lotsSeed, 200);
        int128 fundingIndex =
            int128((int256(fundingSeed % 17) - 8) * 1e18);

        Snapshot memory immediate =
            _runGenerationSettlementScenario(lots, fundingIndex, false);
        Snapshot memory lazy =
            _runGenerationSettlementScenario(lots, fundingIndex, true);

        _assertEquivalent(
            immediate,
            lazy,
            "closed-generation lazy settlement changed economics"
        );
    }

    function _runGenerationSettlementScenario(
        uint96 lots,
        int128 fundingIndex,
        bool lazy
    ) internal returns (Snapshot memory snap) {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), TICK, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 100, 1_000, 10, 5
        );

        _fund(core, token, MAKER);
        _fund(core, token, NEIGHBOR);
        _fund(core, token, TAKER);

        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, TICK, lots);

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Bid,
            TICK,
            lots,
            IOrderBookCore.FillPolicy.IOC
        );

        if (!lazy) {
            vm.prank(MAKER);
            core.settle(IOrderBookCore.Side.Ask, TICK);
        }

        core.setFundingIndex(fundingIndex);

        vm.prank(MAKER);
        core.settle(IOrderBookCore.Side.Ask, TICK);

        vm.prank(TAKER);
        core.settle(IOrderBookCore.Side.Bid, TICK);

        snap = _snapshot(core);
    }

    function _runScenario(
        uint8 mode,
        uint96 makerLots,
        uint96 neighborLots,
        uint96 fillLots,
        int128 fundingIndex
    ) internal returns (Snapshot memory snap) {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), TICK, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 100, 1_000, 10, 5
        );

        AdvancedOrderModule advanced;
        MarketMakerModule marketMaker;
        LiquidationRetirementCaller liquidationCaller;

        if (mode != 0) {
            advanced = new AdvancedOrderModule(address(core), address(oracle));
            marketMaker = new MarketMakerModule(address(core), address(advanced));
            liquidationCaller = new LiquidationRetirementCaller(advanced);

            core.configureAdvancedModule(address(advanced));
            advanced.configureMarketMakerModule(address(marketMaker));
            advanced.configureLiquidationModule(address(liquidationCaller));
        }

        _fund(core, token, MAKER);
        _fund(core, token, NEIGHBOR);
        _fund(core, token, TAKER);

        if (mode == 0) {
            vm.prank(MAKER);
            core.addLiquidity(IOrderBookCore.Side.Ask, TICK, makerLots);
        } else {
            MarketMakerModule.QuoteUpdate[] memory updates =
                new MarketMakerModule.QuoteUpdate[](1);
            updates[0] = MarketMakerModule.QuoteUpdate({
                side: IOrderBookCore.Side.Ask,
                tick: TICK,
                lots: makerLots
            });
            vm.prank(MAKER);
            marketMaker.batchReplaceQuotes(updates);
        }

        vm.prank(NEIGHBOR);
        core.addLiquidity(IOrderBookCore.Side.Ask, TICK, neighborLots);

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Bid,
            TICK,
            fillLots,
            IOrderBookCore.FillPolicy.IOC
        );

        core.setFundingIndex(fundingIndex);

        if (mode == 0) {
            (uint128 shares,,) =
                core.quotes(MAKER, IOrderBookCore.Side.Ask, TICK);
            vm.prank(MAKER);
            core.removeShares(IOrderBookCore.Side.Ask, TICK, shares);
        } else if (mode == 1) {
            MarketMakerModule.QuoteUpdate[] memory updates =
                new MarketMakerModule.QuoteUpdate[](1);
            updates[0] = MarketMakerModule.QuoteUpdate({
                side: IOrderBookCore.Side.Ask,
                tick: TICK,
                lots: 0
            });
            vm.prank(MAKER);
            marketMaker.batchReplaceQuotes(updates);
        } else {
            liquidationCaller.forceCancel(
                MAKER, IOrderBookCore.Side.Ask, TICK
            );
        }

        vm.prank(TAKER);
        core.settle(IOrderBookCore.Side.Bid, TICK);

        snap = _snapshot(core);
    }

    function _snapshot(OrderBookCoreHarness core)
        internal
        view
        returns (Snapshot memory snap)
    {
        (snap.settled, snap.minPosition, snap.maxPosition) =
            core.accountRisk(MAKER);

        (, snap.trading, snap.funding, snap.reserved,) =
            core.accountingStateTest(MAKER);

        snap.protocolFees = core.protocolFeesAccrued();
        (, snap.poolRemaining,) =
            core.pools(IOrderBookCore.Side.Ask, TICK);
        (snap.quoteShares, snap.quoteClaim,) =
            core.quotes(MAKER, IOrderBookCore.Side.Ask, TICK);
        snap.activeQuotes = core.activeQuoteCount(MAKER);

        snap.aggregateEquity =
            core.accountEquity(MAKER) + core.accountEquity(NEIGHBOR)
                + core.accountEquity(TAKER);
    }

    function _assertEquivalent(
        Snapshot memory expected,
        Snapshot memory actual,
        string memory message
    ) internal pure {
        assertEq(int256(actual.settled), int256(expected.settled), message);
        assertEq(int256(actual.minPosition), int256(expected.minPosition), message);
        assertEq(int256(actual.maxPosition), int256(expected.maxPosition), message);
        assertEq(actual.trading, expected.trading, message);
        assertEq(actual.funding, expected.funding, message);
        assertEq(actual.reserved, expected.reserved, message);
        assertEq(actual.protocolFees, expected.protocolFees, message);
        assertEq(actual.poolRemaining, expected.poolRemaining, message);
        assertEq(uint256(actual.quoteShares), uint256(expected.quoteShares), message);
        assertEq(actual.quoteClaim, expected.quoteClaim, message);
        assertEq(uint256(actual.activeQuotes), uint256(expected.activeQuotes), message);
        assertEq(actual.aggregateEquity, expected.aggregateEquity, message);
    }

    function _fund(
        OrderBookCoreHarness core,
        MockERC20 token,
        address account
    ) internal {
        token.mint(account, 10_000_000);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(10_000_000);
    }
}

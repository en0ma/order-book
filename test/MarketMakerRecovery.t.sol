// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase, Vm} from "./TestBase.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MarketMakerRecoveryTest is TestBase {
    OrderBookCore internal core;
    AdvancedOrderModule internal advanced;
    MarketMakerModule internal marketMaker;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    bytes32 internal constant UPDATED_SIG =
        keccak256("ManagedQuoteUpdated(address,uint8,uint16,uint128,uint32)");
    bytes32 internal constant REMOVED_SIG =
        keccak256("ManagedQuoteRemoved(address,uint8,uint16,uint128,uint32)");

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCore(address(token), address(oracle), 40, 1_000, 0, 0);
        advanced = new AdvancedOrderModule(address(core), address(oracle));
        marketMaker = new MarketMakerModule(address(core), address(advanced));

        core.configureAdvancedModule(address(advanced));
        advanced.configureMarketMakerModule(address(marketMaker));

        token.mint(ALICE, 1_000_000);
        token.mint(BOB, 1_000_000);
        vm.prank(ALICE);
        token.approve(address(core), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(core), type(uint256).max);
        vm.prank(ALICE);
        core.depositCollateral(500_000);
        vm.prank(BOB);
        core.depositCollateral(500_000);
    }

    function testManagedQuoteEventsReplayToCanonicalLiveState() public {
        vm.recordLogs();

        _replace(ALICE, IOrderBookCore.Side.Ask, 110, 12);
        _replace(ALICE, IOrderBookCore.Side.Ask, 110, 20);
        _replace(ALICE, IOrderBookCore.Side.Ask, 110, 7);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint128 replayShares, uint32 replayGeneration, bool present) =
            _replay(logs, ALICE, IOrderBookCore.Side.Ask, 110);

        (uint128 shares, uint32 generation) =
            marketMaker.managedQuote(ALICE, IOrderBookCore.Side.Ask, 110);

        assertTrue(present, "replay lost live quote");
        assertEq(uint256(replayShares), uint256(shares), "replay shares mismatch");
        assertEq(
            uint256(replayGeneration),
            uint256(generation),
            "replay generation mismatch"
        );
    }

    function testManagedQuoteEventsReplayTerminalRemoval() public {
        _replace(ALICE, IOrderBookCore.Side.Bid, 90, 15);

        vm.recordLogs();
        _replace(ALICE, IOrderBookCore.Side.Bid, 90, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint128 replayShares,, bool present) =
            _replay(logs, ALICE, IOrderBookCore.Side.Bid, 90);
        (uint128 shares,) =
            marketMaker.managedQuote(ALICE, IOrderBookCore.Side.Bid, 90);

        assertTrue(!present, "replay retained removed quote");
        assertEq(uint256(replayShares), 0, "removed replay shares");
        assertEq(uint256(shares), 0, "canonical quote remained");
    }

    function testManagedQuoteEventsRecoverAcrossGenerationRollover() public {
        _replace(ALICE, IOrderBookCore.Side.Ask, 105, 10);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            10,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.recordLogs();
        _replace(ALICE, IOrderBookCore.Side.Ask, 105, 6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint128 replayShares, uint32 replayGeneration, bool present) =
            _replay(logs, ALICE, IOrderBookCore.Side.Ask, 105);
        (uint128 shares, uint32 generation) =
            marketMaker.managedQuote(ALICE, IOrderBookCore.Side.Ask, 105);

        assertTrue(present, "rollover replay lost replacement");
        assertEq(uint256(replayShares), uint256(shares), "rollover shares mismatch");
        assertEq(
            uint256(replayGeneration),
            uint256(generation),
            "rollover generation mismatch"
        );
    }

    function _replace(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots
    ) internal {
        MarketMakerModule.QuoteUpdate[] memory updates =
            new MarketMakerModule.QuoteUpdate[](1);
        updates[0] = MarketMakerModule.QuoteUpdate({
            side: side,
            tick: tick,
            lots: lots
        });
        vm.prank(maker);
        marketMaker.batchReplaceQuotes(updates);
    }

    function _replay(
        Vm.Log[] memory logs,
        address maker,
        IOrderBookCore.Side side,
        uint16 tick
    )
        internal
        view
        returns (uint128 shares, uint32 generation, bool present)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(marketMaker) || log.topics.length != 4) {
                continue;
            }
            if (
                address(uint160(uint256(log.topics[1]))) != maker
                    || uint8(uint256(log.topics[2])) != uint8(side)
                    || uint16(uint256(log.topics[3])) != tick
            ) {
                continue;
            }

            if (log.topics[0] == UPDATED_SIG) {
                (shares, generation) = abi.decode(log.data, (uint128, uint32));
                present = true;
            } else if (log.topics[0] == REMOVED_SIG) {
                (shares, generation) = abi.decode(log.data, (uint128, uint32));
                shares = 0;
                generation = 0;
                present = false;
            }
        }
    }
}

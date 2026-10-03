// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase, Vm} from "./TestBase.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IntegrationLens} from "../src/deployable/IntegrationLens.sol";
import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {PortfolioAdmissionCoordinator} from "../src/deployable/PortfolioAdmissionCoordinator.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract IndexerReplayTest is TestBase {
    bytes32 internal constant LIQUIDITY_ADDED_SIG =
        keccak256("LiquidityAdded(address,uint8,uint16,uint96,uint128,uint32)");
    bytes32 internal constant LIQUIDITY_REMOVED_SIG =
        keccak256("LiquidityRemoved(address,uint8,uint16,uint96,uint128,uint32)");
    bytes32 internal constant TRADE_SIG =
        keccak256("Trade(address,uint8,uint16,uint96)");

    bytes32 internal constant CONDITIONAL_PLACED_SIG =
        keccak256("ConditionalOrderPlaced(uint64,address,uint8,uint16,uint16,uint96,bool,bool,bool)");
    bytes32 internal constant CONDITIONAL_CANCELLED_SIG =
        keccak256("ConditionalOrderCancelled(uint64)");
    bytes32 internal constant CONDITIONAL_EXECUTED_SIG =
        keccak256("ConditionalOrderExecuted(uint64,uint96)");
    bytes32 internal constant CONDITIONAL_EXPIRY_SIG =
        keccak256("ConditionalExpirySet(uint64,uint64)");

    bytes32 internal constant PORTFOLIO_LOCK_SIG =
        keccak256("PortfolioLockSynchronized(address,int256,uint256,uint256)");

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockERC20 internal token;
    SegmentTreeExtremaOracle internal oracle;
    OrderBookCore internal core;
    AdvancedOrderModule internal advanced;
    IntegrationLens internal lens;

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCore(address(token), address(oracle), 40, 1_000, 0, 0);
        advanced = new AdvancedOrderModule(address(core), address(oracle));
        lens = new IntegrationLens(address(core), address(advanced));

        core.configureAdvancedModule(address(advanced));

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

    function testCoreEventReplayReconstructsAggregatePoolState() public {
        vm.recordLogs();

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 30);
        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 20);

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Bid,
            105,
            17,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Bid, 95, 11);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint96 askLots, uint32 askGeneration) =
            _replayPool(logs, IOrderBookCore.Side.Ask, 105);
        (uint96 bidLots, uint32 bidGeneration) =
            _replayPool(logs, IOrderBookCore.Side.Bid, 95);

        (, uint96 canonicalAsk, uint32 canonicalAskGeneration) =
            core.pools(IOrderBookCore.Side.Ask, 105);
        (, uint96 canonicalBid, uint32 canonicalBidGeneration) =
            core.pools(IOrderBookCore.Side.Bid, 95);

        assertEq(uint256(askLots), uint256(canonicalAsk), "ask replay mismatch");
        assertEq(
            uint256(askGeneration),
            uint256(canonicalAskGeneration),
            "ask generation mismatch"
        );
        assertEq(uint256(bidLots), uint256(canonicalBid), "bid replay mismatch");
        assertEq(
            uint256(bidGeneration),
            uint256(canonicalBidGeneration),
            "bid generation mismatch"
        );
    }

    function testCoreReplaySupportsCheckpointThenDeltaRecovery() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 106, 40);

        (, uint96 checkpointLots, uint32 checkpointGeneration) =
            core.pools(IOrderBookCore.Side.Ask, 106);

        vm.recordLogs();

        vm.prank(BOB);
        core.take(
            IOrderBookCore.Side.Bid,
            106,
            13,
            IOrderBookCore.FillPolicy.IOC
        );

        Vm.Log[] memory delta = vm.getRecordedLogs();
        (uint96 replayLots, uint32 replayGeneration) = _replayPoolFromCheckpoint(
            delta,
            IOrderBookCore.Side.Ask,
            106,
            checkpointLots,
            checkpointGeneration
        );

        (, uint96 canonicalLots, uint32 canonicalGeneration) =
            core.pools(IOrderBookCore.Side.Ask, 106);

        assertEq(uint256(replayLots), uint256(canonicalLots), "checkpoint lots");
        assertEq(
            uint256(replayGeneration),
            uint256(canonicalGeneration),
            "checkpoint generation"
        );
    }

    function testAdvancedLifecycleReplayMatchesCanonicalTerminalState() public {
        vm.recordLogs();

        vm.prank(ALICE);
        uint64 first = advanced.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC,
            false
        );
        vm.prank(ALICE);
        uint64 second = advanced.placeConditionalOrder(
            IOrderBookCore.Side.Ask,
            false,
            100,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC,
            false
        );

        vm.prank(ALICE);
        advanced.setConditionalExpiry(first, uint64(block.timestamp + 300));
        vm.prank(ALICE);
        advanced.setConditionalExpiry(second, uint64(block.timestamp + 300));
        vm.prank(ALICE);
        advanced.linkOCO(first, second);

        advanced.executeConditionalOrder(first);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool firstActive, uint64 firstExpiry) = _replayConditional(logs, first);
        (bool secondActive, uint64 secondExpiry) = _replayConditional(logs, second);

        uint64[] memory ids = new uint64[](2);
        ids[0] = first;
        ids[1] = second;
        IntegrationLens.ConditionalState[] memory states =
            lens.conditionalStates(ids);

        assertTrue(
            firstActive == ((states[0].flags & 1) != 0),
            "first active replay mismatch"
        );
        assertTrue(
            secondActive == ((states[1].flags & 1) != 0),
            "second active replay mismatch"
        );
        assertEq(
            uint256(firstExpiry),
            uint256(states[0].expiry),
            "first expiry replay mismatch"
        );
        assertEq(
            uint256(secondExpiry),
            uint256(states[1].expiry),
            "second expiry replay mismatch"
        );
    }

    function testSetDeleteLifecycleReducerIsDuplicateDeliveryIdempotent() public {
        vm.recordLogs();

        vm.prank(ALICE);
        uint64 orderId = advanced.placeConditionalOrder(
            IOrderBookCore.Side.Bid,
            true,
            100,
            100,
            10,
            IOrderBookCore.FillPolicy.IOC,
            false
        );
        vm.prank(ALICE);
        advanced.setConditionalExpiry(orderId, uint64(block.timestamp + 300));
        vm.prank(ALICE);
        advanced.cancelConditionalOrder(orderId);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool activeOnce, uint64 expiryOnce) =
            _replayConditionalRepeated(logs, orderId, 1);
        (bool activeTwice, uint64 expiryTwice) =
            _replayConditionalRepeated(logs, orderId, 2);

        assertTrue(activeOnce == activeTwice, "duplicate changed active state");
        assertEq(
            uint256(expiryOnce),
            uint256(expiryTwice),
            "duplicate changed expiry state"
        );
    }

    function testPortfolioLockReplayMatchesCanonicalState() public {
        MockERC20 pToken = new MockERC20();
        MockMarkOracle pOracle = new MockMarkOracle(100);
        OrderBookCore pCore =
            new OrderBookCore(address(pToken), address(pOracle), 20, 1_000, 0, 0);

        PortfolioMarginPolicy.MarketInput[] memory policyInputs =
            new PortfolioMarginPolicy.MarketInput[](1);
        policyInputs[0] = PortfolioMarginPolicy.MarketInput({
            core: address(pCore),
            riskGroup: 1,
            marginBps: 1_000,
            hedgeCreditBps: 0
        });
        PortfolioMarginPolicy policy = new PortfolioMarginPolicy(policyInputs);
        PortfolioCollateralVault vault =
            new PortfolioCollateralVault(address(pToken));

        PortfolioAdmissionCoordinator.MarketInput[] memory admissionInputs =
            new PortfolioAdmissionCoordinator.MarketInput[](1);
        admissionInputs[0] = PortfolioAdmissionCoordinator.MarketInput({
            core: address(pCore),
            gateway: address(this)
        });
        PortfolioAdmissionCoordinator coordinator =
            new PortfolioAdmissionCoordinator(
                address(policy),
                address(vault),
                admissionInputs
            );

        vault.configureController(address(coordinator));
        policy.configureSharedCollateralVault(address(vault));
        pCore.configurePortfolioController(address(coordinator));

        pToken.mint(ALICE, 100_000);
        pToken.mint(BOB, 100_000);
        vm.prank(ALICE);
        pToken.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        pToken.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        vault.deposit(20_000);
        vm.prank(BOB);
        vault.deposit(20_000);

        vm.recordLogs();

        vm.prank(ALICE);
        coordinator.addLiquidity(
            0,
            IOrderBookCore.Side.Ask,
            100,
            50
        );
        vm.prank(BOB);
        coordinator.take(
            0,
            IOrderBookCore.Side.Bid,
            100,
            20,
            IOrderBookCore.FillPolicy.IOC
        );
        coordinator.syncAccount(BOB);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        (
            bool found,
            int256 replayEquity,
            uint256 replayRequirement,
            uint256 replayLocked
        ) = _replayPortfolioLock(logs, address(coordinator), BOB);

        assertTrue(found, "portfolio lock event missing");
        assertEq(
            replayEquity,
            policy.portfolioEquity(BOB),
            "portfolio equity replay mismatch"
        );
        assertEq(
            replayRequirement,
            policy.portfolioRequirement(BOB),
            "portfolio requirement replay mismatch"
        );
        assertEq(
            replayLocked,
            vault.lockedCollateral(BOB),
            "portfolio lock replay mismatch"
        );
    }

    function _replayPool(
        Vm.Log[] memory logs,
        IOrderBookCore.Side side,
        uint16 tick
    ) internal view returns (uint96 lots, uint32 generation) {
        return _replayPoolFromCheckpoint(logs, side, tick, 0, 0);
    }

    function _replayPoolFromCheckpoint(
        Vm.Log[] memory logs,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 startingLots,
        uint32 startingGeneration
    ) internal view returns (uint96 lots, uint32 generation) {
        lots = startingLots;
        generation = startingGeneration;

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(core) || log.topics.length != 4) continue;
            if (uint16(uint256(log.topics[3])) != tick) continue;

            if (
                log.topics[0] == LIQUIDITY_ADDED_SIG
                    || log.topics[0] == LIQUIDITY_REMOVED_SIG
            ) {
                if (uint8(uint256(log.topics[2])) != uint8(side)) continue;

                if (log.topics[0] == LIQUIDITY_ADDED_SIG) {
                    (uint96 added,, uint32 eventGeneration) =
                        abi.decode(log.data, (uint96, uint128, uint32));
                    lots += added;
                    generation = eventGeneration;
                } else {
                    (uint96 removed,, uint32 eventGeneration) =
                        abi.decode(log.data, (uint96, uint128, uint32));
                    lots -= removed;
                    generation = eventGeneration;
                }
            } else if (log.topics[0] == TRADE_SIG) {
                IOrderBookCore.Side takerSide =
                    IOrderBookCore.Side(uint8(uint256(log.topics[2])));
                IOrderBookCore.Side makerSide = takerSide == IOrderBookCore.Side.Bid
                    ? IOrderBookCore.Side.Ask
                    : IOrderBookCore.Side.Bid;
                if (makerSide != side) continue;
                uint96 filled = abi.decode(log.data, (uint96));
                lots -= filled;
            }
        }
    }

    function _replayConditional(Vm.Log[] memory logs, uint64 orderId)
        internal
        pure
        returns (bool active, uint64 expiry)
    {
        return _replayConditionalRepeated(logs, orderId, 1);
    }

    function _replayConditionalRepeated(
        Vm.Log[] memory logs,
        uint64 orderId,
        uint256 deliveries
    ) internal pure returns (bool active, uint64 expiry) {
        for (uint256 delivery; delivery < deliveries; ++delivery) {
            for (uint256 i; i < logs.length; ++i) {
                Vm.Log memory log = logs[i];
                if (log.topics.length < 2 || uint64(uint256(log.topics[1])) != orderId) {
                    continue;
                }

                if (log.topics[0] == CONDITIONAL_PLACED_SIG) {
                    active = true;
                } else if (log.topics[0] == CONDITIONAL_EXPIRY_SIG) {
                    expiry = abi.decode(log.data, (uint64));
                } else if (
                    log.topics[0] == CONDITIONAL_CANCELLED_SIG
                        || log.topics[0] == CONDITIONAL_EXECUTED_SIG
                ) {
                    active = false;
                    expiry = 0;
                }
            }
        }
    }

    function _replayPortfolioLock(
        Vm.Log[] memory logs,
        address coordinator,
        address account
    )
        internal
        pure
        returns (
            bool found,
            int256 equity,
            uint256 requirement,
            uint256 locked
        )
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (
                log.emitter != coordinator || log.topics.length != 2
                    || log.topics[0] != PORTFOLIO_LOCK_SIG
                    || address(uint160(uint256(log.topics[1]))) != account
            ) continue;

            (equity, requirement, locked) =
                abi.decode(log.data, (int256, uint256, uint256));
            found = true;
        }
    }
}

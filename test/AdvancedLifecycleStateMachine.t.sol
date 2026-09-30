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

contract AdvancedOrderModuleHarness is AdvancedOrderModule {
    constructor(address core_, address oracle_) AdvancedOrderModule(core_, oracle_) {}

    function nextConditionalId() external view returns (uint64) {
        return nextConditionalOrderId;
    }

    function nextTrailingId() external view returns (uint64) {
        return nextTrailingOrderId;
    }

    function conditionalLive(uint64 id) external view returns (bool live, address owner_) {
        ConditionalOrder storage order = conditionalOrders[id];
        owner_ = order.owner;
        live =
            owner_ != address(0)
                && (
                    (order.flags & FLAG_ACTIVE) != 0
                        || (order.flags & FLAG_DORMANT) != 0
                        || restingLinks[id].active
                );
    }

    function trailingLive(uint64 id) external view returns (bool live, address owner_) {
        TrailingOrder storage order = trailingOrders[id];
        owner_ = order.owner;
        live = owner_ != address(0) && (order.flags & FLAG_ACTIVE) != 0;
    }

    function otoLinks(uint64 id)
        external
        view
        returns (uint64 parent, uint64 firstChild, uint64 secondChild)
    {
        parent = otoParent[id];
        firstChild = otoChildOne[id];
        secondChild = otoChildTwo[id];
    }
}

contract AdvancedLifecycleStateMachineTest is TestBase {
    OrderBookCoreHarness internal core;
    AdvancedOrderModuleHarness internal advanced;
    MarketMakerModule internal marketMaker;
    LiquidationModule internal liquidation;
    SegmentTreeExtremaOracle internal oracle;
    MockERC20 internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant LP = address(0x1A11);

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        core = new OrderBookCoreHarness(address(token), address(oracle), 40, 1_000, 0, 0);
        advanced = new AdvancedOrderModuleHarness(address(core), address(oracle));
        marketMaker = new MarketMakerModule(address(core), address(advanced));
        liquidation = new LiquidationModule(address(core), address(advanced), 500);

        core.configureAdvancedModule(address(advanced));
        advanced.configureMarketMakerModule(address(marketMaker));
        advanced.configureLiquidationModule(address(liquidation));

        _fund(ALICE, 10_000_000);
        _fund(BOB, 10_000_000);
        _fund(LP, 10_000_000);

        _replenish();
        _checkAdvancedInvariants();
    }

    function testFuzz_AdvancedLifecycleSequence(uint256 seed) public {
        uint256 randomness = seed;

        for (uint256 step; step < 8; ++step) {
            randomness = uint256(keccak256(abi.encode(randomness, step)));
            _step(randomness);
            _checkAdvancedInvariants();
        }
    }

    function testAdvancedLifecycleDeterministicCorpus() public {
        for (uint256 seed = 1; seed <= 8; ++seed) {
            uint256 randomness = uint256(keccak256(abi.encode(seed, "advanced")));
            for (uint256 step; step < 20; ++step) {
                randomness = uint256(keccak256(abi.encode(randomness, step)));
                _step(randomness);
                _checkAdvancedInvariants();
            }
        }
    }

    function _step(uint256 r) internal {
        uint256 op = r % 11;
        address owner_ = ((r >> 8) & 1) == 0 ? ALICE : BOB;

        if (op == 0) {
            _placeConditional(owner_, r, false);
        } else if (op == 1) {
            _placeConditional(owner_, r, true);
        } else if (op == 2) {
            _executeConditional(r);
        } else if (op == 3) {
            _cancelConditional(r);
        } else if (op == 4) {
            _placeTrailing(owner_, r);
        } else if (op == 5) {
            _executeTrailing(r);
        } else if (op == 6) {
            _cancelTrailing(r);
        } else if (op == 7) {
            _linkOCO(owner_, r);
        } else if (op == 8) {
            _linkOTO(owner_, r);
        } else if (op == 9) {
            oracle.record(uint16(90 + ((r >> 16) % 21)));
        } else {
            _replenish();
        }
    }

    function _placeConditional(address owner_, uint256 r, bool triggeredLimit)
        internal
    {
        IOrderBookCore.Side side =
            ((r >> 16) & 1) == 0 ? IOrderBookCore.Side.Bid : IOrderBookCore.Side.Ask;
        bool triggerAbove = ((r >> 17) & 1) != 0;
        bool reduceOnly = !triggeredLimit && ((r >> 18) & 1) != 0;
        uint16 triggerTick = uint16(98 + ((r >> 24) % 5));
        uint96 lots = uint96(((r >> 32) % 40) + 1);

        vm.prank(owner_);
        if (triggeredLimit) {
            uint16 limitTick =
                side == IOrderBookCore.Side.Bid ? uint16(99) : uint16(101);
            address(advanced).call(
                abi.encodeCall(
                    advanced.placeTriggeredLimitOrder,
                    (side, triggerAbove, triggerTick, limitTick, lots)
                )
            );
        } else {
            uint16 limitTick =
                side == IOrderBookCore.Side.Bid ? uint16(106) : uint16(94);
            address(advanced).call(
                abi.encodeCall(
                    advanced.placeConditionalOrder,
                    (
                        side,
                        triggerAbove,
                        triggerTick,
                        limitTick,
                        lots,
                        IOrderBookCore.FillPolicy.IOC,
                        reduceOnly
                    )
                )
            );
        }
    }

    function _executeConditional(uint256 r) internal {
        uint64 next = advanced.nextConditionalId();
        if (next <= 1) return;
        uint64 id = uint64(1 + ((r >> 20) % (next - 1)));
        address(advanced).call(abi.encodeCall(advanced.executeConditionalOrder, (id)));
    }

    function _cancelConditional(uint256 r) internal {
        uint64 next = advanced.nextConditionalId();
        if (next <= 1) return;
        uint64 id = uint64(1 + ((r >> 20) % (next - 1)));

        (address owner_,,,,,,,,) = advanced.conditionalOrders(id);
        if (owner_ == address(0)) return;

        vm.prank(owner_);
        address(advanced).call(abi.encodeCall(advanced.cancelConditionalOrder, (id)));
    }

    function _placeTrailing(address owner_, uint256 r) internal {
        IOrderBookCore.Side side =
            ((r >> 16) & 1) == 0 ? IOrderBookCore.Side.Bid : IOrderBookCore.Side.Ask;
        uint16 limitTick =
            side == IOrderBookCore.Side.Bid ? uint16(106) : uint16(94);
        uint16 trailTicks = uint16(((r >> 24) % 5) + 1);
        uint96 lots = uint96(((r >> 32) % 40) + 1);
        bool reduceOnly = ((r >> 18) & 1) != 0;

        vm.prank(owner_);
        address(advanced).call(
            abi.encodeCall(
                advanced.placeTrailingOrder,
                (
                    side,
                    trailTicks,
                    limitTick,
                    lots,
                    IOrderBookCore.FillPolicy.IOC,
                    reduceOnly
                )
            )
        );
    }

    function _executeTrailing(uint256 r) internal {
        uint64 next = advanced.nextTrailingId();
        if (next <= 1) return;
        uint64 id = uint64(1 + ((r >> 20) % (next - 1)));
        address(advanced).call(abi.encodeCall(advanced.executeTrailingOrder, (id)));
    }

    function _cancelTrailing(uint256 r) internal {
        uint64 next = advanced.nextTrailingId();
        if (next <= 1) return;
        uint64 id = uint64(1 + ((r >> 20) % (next - 1)));
        (, address owner_) = advanced.trailingLive(id);
        if (owner_ == address(0)) return;

        vm.prank(owner_);
        address(advanced).call(abi.encodeCall(advanced.cancelTrailingOrder, (id)));
    }

    function _linkOCO(address owner_, uint256 r) internal {
        uint64 next = advanced.nextConditionalId();
        if (next <= 2) return;

        uint64 first = uint64(1 + ((r >> 20) % (next - 1)));
        uint64 second = uint64(1 + ((r >> 40) % (next - 1)));
        if (first == second) return;

        vm.prank(owner_);
        address(advanced).call(abi.encodeCall(advanced.linkOCO, (first, second)));
    }

    function _linkOTO(address owner_, uint256 r) internal {
        uint64 next = advanced.nextConditionalId();
        if (next <= 2) return;

        uint64 parent = uint64(1 + ((r >> 20) % (next - 1)));
        uint64 child = uint64(1 + ((r >> 40) % (next - 1)));
        if (parent == child) return;

        vm.prank(owner_);
        address(advanced).call(abi.encodeCall(advanced.linkOTO, (parent, child)));
    }

    function _replenish() internal {
        _tryAdd(IOrderBookCore.Side.Bid, 95, 100);
        _tryAdd(IOrderBookCore.Side.Ask, 105, 100);
    }

    function _tryAdd(IOrderBookCore.Side side, uint16 tick, uint96 lots) internal {
        vm.prank(LP);
        address(core).call(abi.encodeCall(core.addLiquidity, (side, tick, lots)));
    }

    function _checkAdvancedInvariants() internal view {
        _checkOwner(ALICE);
        _checkOwner(BOB);

        uint64 nextConditional = advanced.nextConditionalId();
        for (uint64 id = 1; id < nextConditional; ++id) {
            (address owner_,, uint64 sibling,,,,,,) = advanced.conditionalOrders(id);

            if (sibling != 0) {
                (address siblingOwner,, uint64 back,,,,,,) =
                    advanced.conditionalOrders(sibling);
                assertTrue(siblingOwner == owner_, "OCO owner mismatch");
                assertEq(uint256(back), uint256(id), "OCO link not symmetric");
            }

            (uint64 parent, uint64 firstChild, uint64 secondChild) =
                advanced.otoLinks(id);

            if (parent != 0) {
                (address parentOwner,,,,,,,,) = advanced.conditionalOrders(parent);
                assertTrue(parentOwner == owner_, "OTO owner mismatch");
                (, uint64 pFirst, uint64 pSecond) = advanced.otoLinks(parent);
                assertTrue(
                    pFirst == id || pSecond == id,
                    "OTO child missing from parent"
                );
            }

            if (firstChild != 0) {
                (uint64 childParent,,) = advanced.otoLinks(firstChild);
                assertEq(uint256(childParent), uint256(id), "OTO first child backlink");
            }
            if (secondChild != 0) {
                (uint64 childParent,,) = advanced.otoLinks(secondChild);
                assertEq(uint256(childParent), uint256(id), "OTO second child backlink");
            }
        }
    }

    function _checkOwner(address owner_) internal view {
        uint256 live;

        uint64 nextConditional = advanced.nextConditionalId();
        for (uint64 id = 1; id < nextConditional; ++id) {
            (bool isLive, address orderOwner) = advanced.conditionalLive(id);
            if (isLive && orderOwner == owner_) ++live;
        }

        uint64 nextTrailing = advanced.nextTrailingId();
        for (uint64 id = 1; id < nextTrailing; ++id) {
            (bool isLive, address orderOwner) = advanced.trailingLive(id);
            if (isLive && orderOwner == owner_) ++live;
        }

        assertEq(
            uint256(advanced.activeAdvancedOrders(owner_)),
            live,
            "advanced live-count drift"
        );

        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(owner_);
        assertTrue(minPosition <= settled, "advanced risk min above settled");
        assertTrue(settled <= maxPosition, "advanced risk settled above max");

        (, uint256 reserved) = core.marginStateTest(owner_);
        assertTrue(
            core.accountEquity(owner_) >= int256(reserved),
            "advanced reserved margin exceeds account equity"
        );
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }
}

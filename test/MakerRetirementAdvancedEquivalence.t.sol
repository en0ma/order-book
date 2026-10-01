// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

/// @notice Advanced resting-order cancellation must preserve canonical core economics.
contract MakerRetirementAdvancedEquivalenceTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);

    uint16 internal constant MARK = 100;
    uint16 internal constant TICK = 103;

    function testFuzz_AdvancedRestingCancelMatchesDirectRetirement(
        uint256 lotsSeed,
        uint256 fillSeed,
        uint256 fundingSeed
    ) public {
        uint96 lots = boundNonZero(lotsSeed, 200);
        uint96 fillLots = uint96(fillSeed % (uint256(lots) + 1));
        int128 fundingIndex =
            int128((int256(fundingSeed % 17) - 8) * 1e18);

        bytes32 direct = _directScenarioDigest(lots, fillLots, fundingIndex);
        bytes32 advanced = _advancedScenarioDigest(lots, fillLots, fundingIndex);

        assertEq(
            uint256(advanced),
            uint256(direct),
            "advanced resting cancellation diverged from core retirement"
        );
    }

    function _directScenarioDigest(
        uint96 lots,
        uint96 fillLots,
        int128 fundingIndex
    ) internal returns (bytes32 digest) {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), MARK, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 40, 1_000, 10, 5
        );

        _fund(core, token, MAKER);
        _fund(core, token, TAKER);

        vm.prank(MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, TICK, lots);

        _takeIfAny(core, fillLots);
        core.setFundingIndex(fundingIndex);

        (uint128 shares,,) =
            core.quotes(MAKER, IOrderBookCore.Side.Bid, TICK);
        if (shares != 0) {
            vm.prank(MAKER);
            core.removeShares(IOrderBookCore.Side.Bid, TICK, shares);
        }

        vm.prank(TAKER);
        core.settle(IOrderBookCore.Side.Ask, TICK);

        digest = _digest(core);
    }

    function _advancedScenarioDigest(
        uint96 lots,
        uint96 fillLots,
        int128 fundingIndex
    ) internal returns (bytes32 digest) {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), MARK, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 40, 1_000, 10, 5
        );
        AdvancedOrderModule advanced =
            new AdvancedOrderModule(address(core), address(oracle));

        core.configureAdvancedModule(address(advanced));
        _fund(core, token, MAKER);
        _fund(core, token, TAKER);

        vm.prank(MAKER);
        uint64 orderId = advanced.placeTriggeredLimitOrder(
            IOrderBookCore.Side.Bid,
            true,
            MARK,
            TICK,
            lots
        );
        advanced.executeConditionalOrder(orderId);

        _takeIfAny(core, fillLots);
        core.setFundingIndex(fundingIndex);

        vm.prank(MAKER);
        advanced.cancelRestingOrder(orderId);
        assertEq(
            advanced.activeAdvancedOrders(MAKER),
            0,
            "advanced retirement left active order"
        );

        vm.prank(TAKER);
        core.settle(IOrderBookCore.Side.Ask, TICK);

        digest = _digest(core);
    }

    function _takeIfAny(OrderBookCoreHarness core, uint96 fillLots) internal {
        if (fillLots == 0) return;

        vm.prank(TAKER);
        core.take(
            IOrderBookCore.Side.Ask,
            TICK,
            fillLots,
            IOrderBookCore.FillPolicy.IOC
        );
    }

    function _digest(OrderBookCoreHarness core) internal view returns (bytes32) {
        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(MAKER);
        (, int256 trading, int256 funding, uint256 reserved,) =
            core.accountingStateTest(MAKER);
        (uint128 totalShares, uint96 remainingLots, uint32 generation) =
            core.pools(IOrderBookCore.Side.Bid, TICK);
        (uint128 shares, uint96 claim, uint32 quoteGeneration) =
            core.quotes(MAKER, IOrderBookCore.Side.Bid, TICK);

        return keccak256(
            abi.encode(
                settled,
                minPosition,
                maxPosition,
                trading,
                funding,
                reserved,
                core.protocolFeesAccrued(),
                totalShares,
                remainingLots,
                generation,
                shares,
                claim,
                quoteGeneration,
                core.activeQuoteCount(MAKER),
                core.accountEquity(MAKER) + core.accountEquity(TAKER)
            )
        );
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

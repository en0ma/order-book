// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

/// @notice Repeated maker settlement around partial retirements must be idempotent.
contract MakerRetirementSequenceEquivalenceTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant NEIGHBOR = address(0xB0B);
    address internal constant TAKER = address(0xCA401);
    uint16 internal constant TICK = 10_000;

    function testFuzz_ExtraSettlesDoNotChangeRetirementEconomics(
        uint256 makerSeed,
        uint256 neighborSeed,
        uint256 fillSeed,
        uint256 burnSeed,
        uint256 fundingSeed
    ) public {
        uint96 makerLots = boundNonZero(makerSeed, 160);
        uint96 neighborLots = boundNonZero(neighborSeed, 160);
        uint96 totalLots = makerLots + neighborLots;
        uint96 fillLots = uint96(fillSeed % (uint256(totalLots) + 1));
        int128 fundingA =
            int128((int256(fundingSeed % 13) - 6) * 1e18);
        int128 fundingB = fundingA + int128(3e18);

        bytes32 canonical = _scenarioDigest(
            makerLots,
            neighborLots,
            fillLots,
            burnSeed,
            fundingA,
            fundingB,
            false
        );
        bytes32 eager = _scenarioDigest(
            makerLots,
            neighborLots,
            fillLots,
            burnSeed,
            fundingA,
            fundingB,
            true
        );

        assertEq(
            uint256(eager),
            uint256(canonical),
            "extra maker settles changed retirement economics"
        );
    }

    function _scenarioDigest(
        uint96 makerLots,
        uint96 neighborLots,
        uint96 fillLots,
        uint256 burnSeed,
        int128 fundingA,
        int128 fundingB,
        bool eagerSettle
    ) internal returns (bytes32) {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), TICK, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 100, 1_000, 10, 5
        );

        _fund(core, token, MAKER);
        _fund(core, token, NEIGHBOR);
        _fund(core, token, TAKER);

        _add(core, MAKER, makerLots);
        _add(core, NEIGHBOR, neighborLots);

        if (fillLots != 0) {
            vm.prank(TAKER);
            core.take(
                IOrderBookCore.Side.Bid,
                TICK,
                fillLots,
                IOrderBookCore.FillPolicy.IOC
            );
        }

        core.setFundingIndex(fundingA);
        if (eagerSettle) {
            vm.prank(MAKER);
            core.settle(IOrderBookCore.Side.Ask, TICK);
        }

        _burnSlice(core, burnSeed);

        core.setFundingIndex(fundingB);
        if (eagerSettle) {
            vm.prank(MAKER);
            core.settle(IOrderBookCore.Side.Ask, TICK);
            vm.prank(MAKER);
            core.settle(IOrderBookCore.Side.Ask, TICK);
        }

        _retireRemainder(core);

        vm.prank(NEIGHBOR);
        core.settle(IOrderBookCore.Side.Ask, TICK);
        vm.prank(TAKER);
        core.settle(IOrderBookCore.Side.Bid, TICK);

        return _digest(core);
    }

    function _burnSlice(OrderBookCoreHarness core, uint256 burnSeed) internal {
        (uint128 shares,, uint32 quoteGeneration) =
            core.quotes(MAKER, IOrderBookCore.Side.Ask, TICK);
        (, , uint32 poolGeneration) =
            core.pools(IOrderBookCore.Side.Ask, TICK);

        if (shares == 0 || quoteGeneration != poolGeneration) return;

        uint128 burnShares = shares == 1
            ? 1
            : uint128((uint256(shares) * ((burnSeed % 49) + 1)) / 100);
        if (burnShares == 0) burnShares = 1;
        if (burnShares > shares) burnShares = shares;

        vm.prank(MAKER);
        core.removeShares(IOrderBookCore.Side.Ask, TICK, burnShares);
    }

    function _retireRemainder(OrderBookCoreHarness core) internal {
        (uint128 shares,, uint32 quoteGeneration) =
            core.quotes(MAKER, IOrderBookCore.Side.Ask, TICK);
        (, , uint32 poolGeneration) =
            core.pools(IOrderBookCore.Side.Ask, TICK);

        if (shares == 0) return;

        if (quoteGeneration != poolGeneration) {
            vm.prank(MAKER);
            core.settle(IOrderBookCore.Side.Ask, TICK);
            return;
        }

        vm.prank(MAKER);
        core.removeShares(IOrderBookCore.Side.Ask, TICK, shares);
    }

    function _digest(OrderBookCoreHarness core) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _accountDigest(core, MAKER),
                _accountDigest(core, NEIGHBOR),
                _accountDigest(core, TAKER),
                _bookDigest(core),
                core.protocolFeesAccrued(),
                core.accountEquity(MAKER) + core.accountEquity(NEIGHBOR)
                    + core.accountEquity(TAKER)
            )
        );
    }

    function _accountDigest(OrderBookCoreHarness core, address account)
        internal
        view
        returns (bytes32)
    {
        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(account);
        (, int256 trading, int256 funding, uint256 reserved,) =
            core.accountingStateTest(account);

        return keccak256(
            abi.encode(
                settled,
                minPosition,
                maxPosition,
                trading,
                funding,
                reserved,
                core.activeQuoteCount(account)
            )
        );
    }

    function _bookDigest(OrderBookCoreHarness core)
        internal
        view
        returns (bytes32)
    {
        (uint128 totalShares, uint96 remainingLots, uint32 generation) =
            core.pools(IOrderBookCore.Side.Ask, TICK);
        (uint128 shares, uint96 claim, uint32 quoteGeneration) =
            core.quotes(MAKER, IOrderBookCore.Side.Ask, TICK);

        return keccak256(
            abi.encode(
                totalShares,
                remainingLots,
                generation,
                shares,
                claim,
                quoteGeneration
            )
        );
    }

    function _add(
        OrderBookCoreHarness core,
        address maker,
        uint96 lots
    ) internal {
        vm.prank(maker);
        core.addLiquidity(IOrderBookCore.Side.Ask, TICK, lots);
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

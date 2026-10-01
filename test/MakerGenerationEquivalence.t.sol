// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract MakerGenerationEquivalenceTest is TestBase {
    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xCA401);
    uint16 internal constant TICK = 10_000;

    function testFuzz_ClosedGenerationLazySettlementMatchesImmediateMaterialization(
        uint256 lotsSeed,
        uint256 fundingSeed
    ) public {
        uint96 lots = boundNonZero(lotsSeed, 200);
        int128 fundingIndex =
            int128((int256(fundingSeed % 17) - 8) * 1e18);

        bytes32 immediate = _scenarioDigest(lots, fundingIndex, false);
        bytes32 lazy = _scenarioDigest(lots, fundingIndex, true);

        assertEq(
            uint256(immediate),
            uint256(lazy),
            "closed-generation lazy settlement changed economics"
        );
    }

    function _scenarioDigest(
        uint96 lots,
        int128 fundingIndex,
        bool lazy
    ) internal returns (bytes32 digest) {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), TICK, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 100, 1_000, 10, 5
        );

        _fund(core, token, MAKER);
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

        digest = _digest(core);
    }

    function _digest(OrderBookCoreHarness core) internal view returns (bytes32) {
        (int80 settled, int80 minPosition, int80 maxPosition) =
            core.accountRisk(MAKER);
        (, int256 trading, int256 funding, uint256 reserved,) =
            core.accountingStateTest(MAKER);
        (, uint96 remaining,) = core.pools(IOrderBookCore.Side.Ask, TICK);
        (uint128 shares, uint96 claim,) =
            core.quotes(MAKER, IOrderBookCore.Side.Ask, TICK);

        return keccak256(
            abi.encode(
                settled,
                minPosition,
                maxPosition,
                trading,
                funding,
                reserved,
                core.protocolFeesAccrued(),
                remaining,
                shares,
                claim,
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

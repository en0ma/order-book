// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCoreHarness} from "./harness/OrderBookCoreHarness.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract CustodyReserveBackingInvariantTest is TestBase {
    address internal constant TRADER = address(0xCA01);
    address internal constant ASK_MAKER = address(0xCA02);
    address internal constant BID_MAKER = address(0xCA03);
    address internal constant WITHDRAWER = address(0xCA04);
    address internal constant LIQUIDATOR = address(0xCA05);

    function testWithdrawalRewardAndInsurancePreserveCustodyBacking() public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        OrderBookCoreHarness core = new OrderBookCoreHarness(
            address(token), address(oracle), 40, 1_000, 100, 0
        );
        AdvancedOrderModule module =
            new AdvancedOrderModule(address(core), address(oracle));
        LiquidationModule liquidation =
            new LiquidationModule(address(core), address(module), address(0), 500);

        core.configureAdvancedModule(address(module));
        module.configureLiquidationModule(address(liquidation));
        liquidation.configureLiquidatorReward(100);

        _fund(core, token, TRADER, 3_000);
        _fund(core, token, ASK_MAKER, 100_000);
        _fund(core, token, BID_MAKER, 100_000);
        _fund(core, token, WITHDRAWER, 20_000);

        token.mint(address(this), 10_000);
        token.approve(address(core), type(uint256).max);
        core.fundInsurance(10_000);

        vm.prank(WITHDRAWER);
        core.withdrawCollateral(5_000);
        _assertBacked(core, token, TRADER, ASK_MAKER, BID_MAKER, WITHDRAWER);

        vm.prank(ASK_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        vm.prank(TRADER);
        core.take(
            IOrderBookCore.Side.Bid,
            100,
            100,
            IOrderBookCore.FillPolicy.IOC
        );

        vm.prank(ASK_MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);

        oracle.record(10);

        vm.prank(BID_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 10, 100);

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionalIds = new uint64[](0);
        uint64[] memory trailingIds = new uint64[](0);

        vm.prank(LIQUIDATOR);
        uint96 closed = liquidation.liquidate(
            TRADER,
            sides,
            ticks,
            conditionalIds,
            trailingIds,
            new uint64[](0)
        );
        assertEq(closed, 100, "liquidation did not fully close");

        vm.prank(BID_MAKER);
        core.settle(IOrderBookCore.Side.Bid, 10);

        assertEq(token.balanceOf(LIQUIDATOR), 10, "liquidator reward mismatch");
        assertEq(core.protocolFeesAccrued(), 100, "protocol fee reserve mismatch");
        assertEq(core.insuranceReserves(), 3_890, "insurance reserve mismatch");
        assertEq(liquidation.terminalBadDebt(TRADER), 0, "insurance left bad debt");

        _assertBacked(core, token, TRADER, ASK_MAKER, BID_MAKER, WITHDRAWER);
    }

    function _assertBacked(
        OrderBookCoreHarness core,
        MockERC20 token,
        address first,
        address second,
        address third,
        address fourth
    ) internal view {
        int256 userClaims =
            _cashClaim(core, first) + _cashClaim(core, second)
                + _cashClaim(core, third) + _cashClaim(core, fourth);

        assertTrue(userClaims >= 0, "aggregate tracked cash claim negative");

        uint256 internalClaims =
            uint256(userClaims) + core.protocolFeesAccrued()
                + core.insuranceReserves();

        assertTrue(
            internalClaims <= token.balanceOf(address(core)),
            "internal claims exceed actual custody"
        );
    }

    function _cashClaim(OrderBookCoreHarness core, address account)
        internal
        view
        returns (int256)
    {
        (uint256 collateral, int256 trading, int256 funding,,) =
            core.accountingStateTest(account);
        return int256(collateral) + trading + funding;
    }

    function _fund(
        OrderBookCoreHarness core,
        MockERC20 token,
        address account,
        uint256 amount
    ) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }
}

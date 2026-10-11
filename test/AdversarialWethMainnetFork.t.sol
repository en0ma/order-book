// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {BoundedFundingUpdater} from "../src/deployable/BoundedFundingUpdater.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";

interface IAuditWeth {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Adversarial controls on actual mainnet WETH, not a mock collateral token.
/// @dev Exercises the real matching/risk/liquidation/funding modules on a mainnet fork.
contract AdversarialWethMainnetForkTest is TestBase {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant TRADER = address(0xA11CE);
    address constant MAKER = address(0xB0B);
    address constant OPERATOR = address(0xF00D);
    address constant ATTACKER = address(0xBAD);

    function _fork() internal returns (OrderBookCore core, SegmentTreeExtremaOracle oracle, LiquidationModule liquidation) {
        vm.createSelectFork(vm.envString("ETH_RPC"));
        assertEq(block.chainid, 1, "requires Ethereum mainnet fork");
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3600);
        core = new OrderBookCore(WETH, address(oracle), 30, 1000, 0, 0);
        AdvancedOrderModule advanced = new AdvancedOrderModule(address(core), address(oracle));
        liquidation = new LiquidationModule(address(core), address(advanced), address(0), 500);
        core.configureAdvancedModule(address(advanced));
        advanced.configureLiquidationModule(address(liquidation));
    }

    function _deposit(address who, OrderBookCore core, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        IAuditWeth(WETH).deposit{value: amount}();
        vm.prank(who);
        IAuditWeth(WETH).approve(address(core), type(uint256).max);
        vm.prank(who);
        core.depositCollateral(amount);
    }

    function testForkFundingAuthorityRotationBypassesWrapperAccounting() public {
        (OrderBookCore core,,) = _fork();
        BoundedFundingUpdater updater = new BoundedFundingUpdater(address(core), OPERATOR, 3600, 5e16);
        core.setFundingUpdater(address(updater));

        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        updater.publish(1);
        assertEq(int256(updater.lastIndexX18()), 1, "bounded index");

        // Governance retains ultimate index control; wrapper does NOT detect this.
        core.setFundingUpdater(address(this));
        core.setFundingIndex(int128(1e18));
        core.setFundingUpdater(address(updater));
        vm.warp(block.timestamp + 3600);
        vm.prank(OPERATOR);
        updater.publish(2);
        assertEq(int256(updater.lastIndexX18()), 2, "wrapper index");
        // A published 2 is a large absolute jump from the actual Core index 1e18.
        // Its risk bounds only cover uninterrupted operator control.
        vm.prank(OPERATOR);
        updater.pauseRiskIncrease();
        assertTrue(core.riskIncreasePaused(), "emergency pause forwarding lost");
    }

    function testForkDistressedOpenMakerQuoteMustBeCancelledBeforeLiquidation() public {
        (OrderBookCore core, SegmentTreeExtremaOracle oracle, LiquidationModule liquidation) = _fork();
        _deposit(TRADER, core, 1400);
        _deposit(MAKER, core, 100_000);
        uint256 custody = IAuditWeth(WETH).balanceOf(address(core));
        // Distressed account is a bid-side maker, with a partially unfilled resting quote.
        vm.prank(TRADER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 100, 100);
        vm.prank(MAKER);
        core.take(IOrderBookCore.Side.Ask, 100, 90, IOrderBookCore.FillPolicy.IOC);
        vm.prank(TRADER);
        core.settle(IOrderBookCore.Side.Bid, 100);
        oracle.record(80);

        assertTrue(!liquidation.isLiquidatable(TRADER), "open quote should block liquidation");
        IOrderBookCore.Side[] memory emptySides = new IOrderBookCore.Side[](0);
        uint16[] memory emptyTicks = new uint16[](0);
        uint64[] memory emptyIds = new uint64[](0);
        (bool withoutCleanup,) = address(liquidation).call(abi.encodeCall(
            liquidation.liquidate, (TRADER, emptySides, emptyTicks, emptyIds, emptyIds, emptyIds)
        ));
        assertTrue(!withoutCleanup, "liquidated without maker cleanup");

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](1);
        sides[0] = IOrderBookCore.Side.Bid;
        uint16[] memory ticks = new uint16[](1);
        ticks[0] = 100;
        uint96 closed = liquidation.liquidate(TRADER, sides, ticks, emptyIds, emptyIds, emptyIds);
        assertEq(uint256(closed), 0, "missing opposing book invented closeout fill");
        (int80 position,,) = core.accountRisk(TRADER);
        assertEq(int256(position), 90, "empty book changed distressed position");
        assertEq(IAuditWeth(WETH).balanceOf(address(core)), custody, "liquidation changed real WETH custody");
    }

    function testForkNoCrossAccountCollateralWithdrawal() public {
        (OrderBookCore core,,) = _fork();
        _deposit(MAKER, core, 1 ether);
        uint256 custody = IAuditWeth(WETH).balanceOf(address(core));
        vm.prank(ATTACKER);
        (bool stole,) = address(core).call(abi.encodeCall(core.withdrawCollateral, (1)));
        assertTrue(!stole, "unfunded attacker withdrew collateral");
        assertEq(IAuditWeth(WETH).balanceOf(address(core)), custody, "custody changed");
    }
}

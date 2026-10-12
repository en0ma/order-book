// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @dev Sets an already-settled long position and its historical cashflow.
///      The closeout itself uses the real maker book, gateway, and liquidation module.
contract LiquidationExecutionCoreHarness is OrderBookCore {
    constructor(address token, address oracle)
        OrderBookCore(token, oracle, 30, 1000, 0, 0) {}

    function seedPosition(address account, int80 position, int256 cashflow) external {
        accountRisk[account] = AccountRisk(position, position, position);
        tradeCashflow[account] = cashflow;
    }
}

/// @notice Manipulated marks can initiate real liquidation matching, not just a read-side flip.
/// @dev Oracle control is a compromised-feed assumption, not a permissionless exploit.
contract OracleLiquidationExecutionTest is TestBase {
    MockERC20 internal token;
    MockMarkOracle internal oracle;
    LiquidationExecutionCoreHarness internal core;
    AdvancedOrderModule internal advanced;
    LiquidationModule internal liquidation;
    address internal trader = address(0xA11CE);
    address internal maker = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        oracle = new MockMarkOracle(100);
        core = new LiquidationExecutionCoreHarness(address(token), address(oracle));
        core.configureAccountingUnitScale(1);
        advanced = new AdvancedOrderModule(address(core), address(oracle));
        liquidation = new LiquidationModule(address(core), address(advanced), address(0), 500);
        core.configureAdvancedModule(address(advanced));
        advanced.configureLiquidationModule(address(liquidation));

        token.mint(trader, 1000);
        vm.prank(trader);
        token.approve(address(core), 1000);
        vm.prank(trader);
        core.depositCollateral(1000);

        token.mint(maker, 20000);
        vm.prank(maker);
        token.approve(address(core), 20000);
        vm.prank(maker);
        core.depositCollateral(20000);

        core.seedPosition(trader, 100, -9800);
    }

    function testManipulatedMarkExecutesLiquidationAgainstRestingBid() public {
        vm.prank(maker);
        core.addLiquidity(IOrderBookCore.Side.Bid, 90, 100);

        assertTrue(!liquidation.isLiquidatable(trader), "healthy account liquidatable");
        assertEq(core.accountEquity(trader), int256(1200), "initial equity mismatch");

        oracle.setMarkTick(90);
        assertTrue(liquidation.isLiquidatable(trader), "mark did not enable liquidation");

        uint256 custodyBefore = token.balanceOf(address(core));
        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory empty = new uint64[](0);
        uint96 closed = liquidation.liquidate(trader, sides, ticks, empty, empty, empty);

        assertEq(uint256(closed), 100, "position not fully closed");
        (int80 position,,) = core.accountRisk(trader);
        assertEq(int256(position), int256(0), "position remains open");
        assertEq(core.accountEquity(trader), int256(200), "post-closeout equity mismatch");
        assertEq(token.balanceOf(address(core)), custodyBefore, "unexpected transfer from custody");
        assertEq(token.balanceOf(trader), 0, "unexpected direct payout");
        assertEq(liquidation.terminalBadDebt(trader), 0, "unexpected terminal debt");
    }

    function testWithoutManipulationPositionCannotBeLiquidated() public {
        vm.prank(maker);
        core.addLiquidity(IOrderBookCore.Side.Bid, 90, 100);
        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory empty = new uint64[](0);
        (bool succeeded,) = address(liquidation).call(
            abi.encodeCall(liquidation.liquidate, (trader, sides, ticks, empty, empty, empty))
        );
        assertTrue(!succeeded, "healthy trader liquidated");
        (int80 position,,) = core.accountRisk(trader);
        assertEq(int256(position), int256(100), "failed liquidation changed position");
        assertEq(token.balanceOf(address(core)), 21000, "failed liquidation changed custody");
    }
}

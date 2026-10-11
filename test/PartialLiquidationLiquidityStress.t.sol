// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Actual matching and liquidation contracts with an actual extrema mark oracle.
/// @dev Only the ERC20 is a local test token; no risk, pricing or matching contract is mocked.
contract PartialLiquidationLiquidityStressTest is TestBase {
    MockERC20 token;
    SegmentTreeExtremaOracle oracle;
    OrderBookCore core;
    AdvancedOrderModule advanced;
    LiquidationModule liquidation;
    address constant TRADER = address(0xA11CE);
    address constant ENTRY_MAKER = address(0xB0B);
    address constant EXIT_MAKER = address(0xCAFE);
    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3600);
        core = new OrderBookCore(address(token), address(oracle), 30, 1000, 0, 0);
        advanced = new AdvancedOrderModule(address(core), address(oracle));
        liquidation = new LiquidationModule(address(core), address(advanced), address(0), 500);
        core.configureAdvancedModule(address(advanced));
        advanced.configureLiquidationModule(address(liquidation));
        _deposit(TRADER, 1400);
        _deposit(ENTRY_MAKER, 100000);
        _deposit(EXIT_MAKER, 100000);
        vm.prank(ENTRY_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TRADER);
        assertEq(core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC), 100, "entry fill");
        vm.prank(ENTRY_MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);
        oracle.record(80);
        assertTrue(liquidation.isLiquidatable(TRADER), "mark loss must breach maintenance");
    }
    function testEmptyBookCannotCreateFictitiousLiquidationOrInsuranceCoverage() public {
        uint256 equityBefore = uint256(token.balanceOf(address(core)));
        _liquidate(0);
        (int80 remaining,,) = core.accountRisk(TRADER);
        assertEq(int256(remaining), 100, "empty book closed position");
        assertEq(token.balanceOf(address(core)), equityBefore, "empty fill changed custody");
        assertEq(core.insuranceReserves(), 0, "unfunded insurance changed");
        assertTrue(liquidation.isLiquidatable(TRADER), "empty book erroneously healed account");
    }
    function testRepeatedPartialThenCompleteLiquidationPreservesPositionsAndCustody() public {
        uint256 custody = token.balanceOf(address(core));
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 40);
        _liquidate(40);
        (int80 remaining,,) = core.accountRisk(TRADER);
        assertEq(int256(remaining), 60, "first liquidation overclosed");
        assertEq(token.balanceOf(address(core)), custody, "partial liquidation changed custody");
        vm.prank(EXIT_MAKER);
        core.settle(IOrderBookCore.Side.Bid, 80);
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 60);
        _liquidate(60);
        (remaining,,) = core.accountRisk(TRADER);
        assertEq(int256(remaining), 0, "second liquidation left residual lots");
        assertEq(token.balanceOf(address(core)), custody, "liquidation created/destroyed tokens");
        assertTrue(!liquidation.isLiquidatable(TRADER), "flat position still liquidatable");
    }
    function _deposit(address actor, uint256 amount) internal {
        token.mint(actor, amount);
        vm.prank(actor); token.approve(address(core), type(uint256).max);
        vm.prank(actor); core.depositCollateral(amount);
    }
    function _liquidate(uint256 expected) internal {
        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory ids = new uint64[](0);
        uint96 closed = liquidation.liquidate(TRADER, sides, ticks, ids, ids, ids);
        assertEq(uint256(closed), expected, "liquidation filled wrong lots");
    }
}

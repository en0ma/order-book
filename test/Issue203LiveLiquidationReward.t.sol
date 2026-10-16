// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Fee-distribution accounting must not prevent earned liquidator
/// rewards on real partial liquidations or convert them into treasury fees.
contract Issue203LiveLiquidationRewardTest is TestBase {
    address internal constant TRADER = address(0xA11CE);
    address internal constant ENTRY_MAKER = address(0xB0B);
    address internal constant EXIT_MAKER = address(0xCAFE);
    address internal constant TREASURY = address(0xFEED);

    MockERC20 internal token;
    OrderBookCore internal core;
    SegmentTreeExtremaOracle internal oracle;
    LiquidationModule internal liquidation;

    function setUp() public {
        token = new MockERC20();
        oracle = new SegmentTreeExtremaOracle(address(this), 100, 3600);
        core = new OrderBookCore(address(token), address(oracle), 30, 1000, 100, 0);
        AdvancedOrderModule gateway = new AdvancedOrderModule(address(core), address(oracle));
        liquidation = new LiquidationModule(address(core), address(gateway), address(0), 500);
        core.configureAdvancedModule(address(gateway));
        gateway.configureLiquidationModule(address(liquidation));
        liquidation.configureLiquidatorReward(100);

        _deposit(TRADER, 1400);
        _deposit(ENTRY_MAKER, 100000);
        _deposit(EXIT_MAKER, 100000);

        vm.prank(ENTRY_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TRADER);
        core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(ENTRY_MAKER);
        core.settle(IOrderBookCore.Side.Ask, 100);
        oracle.record(80);
        assertTrue(liquidation.isLiquidatable(TRADER), "not liquidatable at stressed mark");

        core.configureTreasuryRecipient(TREASURY);
        core.setFeeDistributionEnabled(true);
    }

    function _deposit(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }

    function test_RealPartialLiquidationRewardPreservesExistingEarnedFeePayment() public {
        vm.prank(EXIT_MAKER);
        core.addLiquidity(IOrderBookCore.Side.Bid, 80, 40);
        uint256 beforeCustody = token.balanceOf(address(core));
        uint256 beforeLiquidator = token.balanceOf(address(this));
        uint256 beforeFees = core.protocolFeesAccrued();

        IOrderBookCore.Side[] memory sides = new IOrderBookCore.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory ids = new uint64[](0);
        uint96 closed = liquidation.liquidate(TRADER, sides, ticks, ids, ids, ids);

        assertEq(uint256(closed), 40, "partial liquidation fill mismatch");
        assertEq(token.balanceOf(address(this)) - beforeLiquidator, 32,
            "genuine liquidation reward was not delivered");
        assertEq(token.balanceOf(address(core)), beforeCustody - 32,
            "liquidation reward physical custody mismatch");
        assertEq(core.protocolFeesAccrued(), beforeFees + 32 - 32,
            "liquidation fee and earned reward accounting mismatch");
        assertEq(token.balanceOf(TREASURY), 0, "liquidation reward redirected to treasury");

        // The liquidation generated maker/taker exposure and insurance timing.
        // Treasury distribution must remain impossible until all liabilities
        // are fully settled and the on-chain global proof can succeed.
        (bool treasurySucceeded,) = address(core).call(
            abi.encodeCall(core.withdrawProtocolFees, (uint256(1)))
        );
        assertTrue(!treasurySucceeded, "open partial liquidation enabled treasury extraction");
    }
}

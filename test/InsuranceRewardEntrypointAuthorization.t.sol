// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @notice Untrusted callers must not invoke Core's insurance or reward payout hooks.
contract InsuranceRewardEntrypointAuthorizationTest is TestBase {
    function testUntrustedCallerCannotDrainFundedInsuranceOrAccruedFees() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle mark = new MockMarkOracle(100);
        OrderBookCore core = new OrderBookCore(address(token), address(mark), 30, 1000, 100, 0);
        AdvancedOrderModule advanced = new AdvancedOrderModule(address(core), address(mark));
        core.configureAdvancedModule(address(advanced));

        address maker = address(0xB0B);
        address taker = address(0xA11CE);
        address attacker = address(0xBAD);

        token.mint(maker, 20000);
        vm.prank(maker);
        token.approve(address(core), 20000);
        vm.prank(maker);
        core.depositCollateral(20000);

        token.mint(taker, 20000);
        vm.prank(taker);
        token.approve(address(core), 20000);
        vm.prank(taker);
        core.depositCollateral(20000);

        token.mint(address(this), 500);
        token.approve(address(core), 500);
        core.fundInsurance(500);

        vm.prank(maker);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(taker);
        uint96 filled =
            core.take(IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        assertEq(uint256(filled), 100, "fee-generating trade failed");

        uint256 insuranceBefore = core.insuranceReserves();
        uint256 feesBefore = core.protocolFeesAccrued();
        uint256 custodyBefore = token.balanceOf(address(core));
        assertEq(insuranceBefore, 500, "no funded insurance");
        assertTrue(feesBefore > 0, "no accrued fee reserve");

        vm.prank(attacker);
        (bool covered,) = address(core).call(
            abi.encodeCall(core.moduleCoverBadDebt, (attacker, uint256(500)))
        );
        assertTrue(!covered, "unauthorized caller invoked insurance payout");

        vm.prank(attacker);
        (bool rewarded,) = address(core).call(
            abi.encodeCall(core.modulePayLiquidationReward, (attacker, uint256(100)))
        );
        assertTrue(!rewarded, "unauthorized caller invoked reward payout");

        assertEq(core.insuranceReserves(), insuranceBefore, "unauthorized insurance mutation");
        assertEq(core.protocolFeesAccrued(), feesBefore, "unauthorized fee mutation");
        assertEq(token.balanceOf(address(core)), custodyBefore, "unauthorized custody drain");
        assertEq(token.balanceOf(attacker), 0, "attacker received tokens");
    }
}

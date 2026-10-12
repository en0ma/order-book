// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @notice Untrusted callers cannot invoke reserve-spending liquidation gateway hooks.
contract LiquidationGatewayReserveAuthTest is TestBase {
    function testAttackerCannotBypassLiquidationModuleToSpendInsuranceOrFees() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle mark = new MockMarkOracle(100);
        OrderBookCore core = new OrderBookCore(address(token), address(mark), 30, 1000, 0, 0);
        AdvancedOrderModule gateway = new AdvancedOrderModule(address(core), address(mark));
        LiquidationModule liquidation =
            new LiquidationModule(address(core), address(gateway), address(0), 500);
        core.configureAdvancedModule(address(gateway));
        gateway.configureLiquidationModule(address(liquidation));

        token.mint(address(this), 500);
        token.approve(address(core), 500);
        core.fundInsurance(500);

        address attacker = address(0xBAD);
        uint256 beforeCustody = token.balanceOf(address(core));
        uint256 beforeInsurance = core.insuranceReserves();
        uint256 beforeFees = core.protocolFeesAccrued();

        vm.prank(attacker);
        (bool insured,) = address(gateway).call(
            abi.encodeCall(gateway.liquidationCoverBadDebt, (attacker, uint256(500)))
        );
        assertTrue(!insured, "untrusted caller spent insurance via gateway");

        vm.prank(attacker);
        (bool rewarded,) = address(gateway).call(
            abi.encodeCall(gateway.liquidationPayReward, (attacker, uint256(500)))
        );
        assertTrue(!rewarded, "untrusted caller claimed reward via gateway");

        assertEq(core.insuranceReserves(), beforeInsurance, "insurance changed");
        assertEq(core.protocolFeesAccrued(), beforeFees, "fee reserve changed");
        assertEq(token.balanceOf(address(core)), beforeCustody, "custody changed");
        assertEq(token.balanceOf(attacker), 0, "attacker received collateral");
    }
}

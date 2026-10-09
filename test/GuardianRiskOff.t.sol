// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract GuardianRiskOffTest is TestBase {
    function testRiskOffGuardsDirectMatchingAndLeavesCancellationAvailable() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        OrderBookCore core = new OrderBookCore(address(token), address(oracle), 40, 1000, 0, 0);
        address maker = address(0xB0B);
        address guardian = address(0xBEEF);
        core.setGuardian(guardian);
        vm.prank(maker);
        core.addLiquidity(OrderBookCore.Side.Ask, 100, 100);
        vm.prank(guardian);
        core.setRiskIncreasePaused(true);
        (bool ok,) = address(core).call(abi.encodeCall(core.take,
            (OrderBookCore.Side.Bid, uint16(100), uint96(1), OrderBookCore.FillPolicy.IOC)));
        assertTrue(!ok, "risk-on take must fail during guardian pause");
        vm.prank(maker);
        (ok,) = address(core).call(abi.encodeCall(core.addLiquidity,
            (OrderBookCore.Side.Ask, uint16(100), uint96(1))));
        assertTrue(!ok, "new maker exposure must fail during guardian pause");
        vm.prank(maker);
        core.removeShares(OrderBookCore.Side.Ask, 100, 1);
        vm.prank(guardian);
        (ok,) = address(core).call(abi.encodeCall(core.setRiskIncreasePaused, (false)));
        assertTrue(!ok, "guardian cannot reactivate trading");
        core.setRiskIncreasePaused(false);
        assertTrue(!core.riskIncreasePaused(), "owner can restore risk-taking");
    }
}

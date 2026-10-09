// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract GuardianRiskOffTest is TestBase {
    function testRiskOffGuardsDirectMatchingAndLeavesCancellationAvailable() public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        OrderBookCore core = new OrderBookCore(address(token), address(oracle), 40, 1000, 0, 0);
        address maker = address(0xB0B);
        address guardian = address(0xBEEF);
        core.configureRiskControl(guardian, false);
        token.mint(maker, 10_000);
        vm.prank(maker);
        token.approve(address(core), 10_000);
        vm.prank(maker);
        core.depositCollateral(10_000);
        vm.prank(maker);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(guardian);
        core.configureRiskControl(guardian, true);
        (bool ok,) = address(core).call(abi.encodeCall(core.take,
            (IOrderBookCore.Side.Bid, uint16(100), uint96(1), IOrderBookCore.FillPolicy.IOC)));
        assertTrue(!ok, "risk-on take must fail during guardian pause");
        vm.prank(maker);
        (ok,) = address(core).call(abi.encodeCall(core.addLiquidity,
            (IOrderBookCore.Side.Ask, uint16(100), uint96(1))));
        assertTrue(!ok, "new maker exposure must fail during guardian pause");
        vm.prank(maker);
        core.removeShares(IOrderBookCore.Side.Ask, 100, 1);
        vm.prank(guardian);
        (ok,) = address(core).call(abi.encodeCall(core.configureRiskControl, (guardian, false)));
        assertTrue(!ok, "guardian cannot reactivate trading");
        core.configureRiskControl(guardian, false);
        assertTrue(!core.riskIncreasePaused(), "owner can restore risk-taking");
    }
}

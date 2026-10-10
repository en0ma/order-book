// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract AdversarialRiskOffFuzzTest is TestBase {
    function testFuzz_PausedRiskNeverAdmitsNewMakersOrTakers(uint96 rawLots, bool useBid) public {
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        OrderBookCore core = new OrderBookCore(address(token), address(oracle), 30, 1000, 0, 0);
        address maker = address(0xB0B);
        address taker = address(0xA11CE);
        address guardian = address(0xBEEF);
        address[2] memory actors = [maker,taker];
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], 1_000_000);
            vm.prank(actors[i]); token.approve(address(core), type(uint256).max);
            vm.prank(actors[i]); core.depositCollateral(1_000_000);
        }
        IOrderBookCore.Side makerSide = useBid ? IOrderBookCore.Side.Bid : IOrderBookCore.Side.Ask;
        IOrderBookCore.Side takerSide = useBid ? IOrderBookCore.Side.Ask : IOrderBookCore.Side.Bid;
        vm.prank(maker); core.addLiquidity(makerSide, 100, 10);
        core.setFundingUpdater(guardian);
        vm.prank(guardian); core.setRiskIncreasePaused(true);
        uint96 lots = uint96(uint256(rawLots) % 10 + 1);
        vm.prank(taker);
        (bool takerOk,) = address(core).call(abi.encodeCall(core.take,
            (takerSide, uint16(100), lots, IOrderBookCore.FillPolicy.IOC)));
        assertTrue(!takerOk, "paused matching accepted");
        vm.prank(maker);
        (bool makerOk,) = address(core).call(abi.encodeCall(core.addLiquidity,
            (makerSide, uint16(100), lots)));
        assertTrue(!makerOk, "paused quote admitted");
        vm.prank(maker); core.removeShares(makerSide, 100, 1);
        assertTrue(core.riskIncreasePaused(), "cancellation cleared guardian pause");
    }
}

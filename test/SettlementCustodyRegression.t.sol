// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

contract SettlementCustodyRegressionTest is TestBase {
    function testFuzz_DepositWithdrawPreservesExactTokenCustody(uint96 rawAmount) public {
        uint256 amount = uint256(rawAmount) % 1_000_000 + 1;
        MockERC20 token = new MockERC20();
        MockMarkOracle oracle = new MockMarkOracle(100);
        OrderBookCore core = new OrderBookCore(address(token), address(oracle), 30, 1000, 0, 0);
        address trader = address(0xA11CE);
        token.mint(trader, amount);
        vm.prank(trader); token.approve(address(core), type(uint256).max);
        vm.prank(trader); core.depositCollateral(amount);
        assertEq(token.balanceOf(address(core)), amount, "deposit short custody");
        uint256 half = amount / 2;
        if (half != 0) {
            vm.prank(trader); core.withdrawCollateral(half);
            assertEq(token.balanceOf(address(core)), amount - half, "partial withdrawal custody");
        }
        vm.prank(trader); core.withdrawCollateral(amount - half);
        assertEq(token.balanceOf(address(core)), 0, "final custody not zero");
        assertEq(token.balanceOf(trader), amount, "withdrawal did not restore tokens");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioTwoMarketFeeIsolationTest} from "./PortfolioTwoMarketFeeIsolation.t.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

/// @notice FEE-03 red-line regression: accrued fees are not a payout authorization.
/// @dev This is a prerequisite for the future positive on-chain solvency proof.
contract Issue203TreasuryPayoutBoundaryTest is PortfolioTwoMarketFeeIsolationTest {
    function testFuzz_MultiMarketAccrualCannotAuthorizeTreasuryExit(uint16 seed) public {
        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        coordinator.take(0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);
        vm.prank(MAKER);
        coordinator.addLiquidity(1, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        coordinator.take(1, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);

        assertEq(core0.protocolFeesAccrued(), 50, "first fee not earned");
        assertEq(core1.protocolFeesAccrued(), 200, "second fee not earned");
        core0.allocateProtocolFeesToInsurance(uint256(seed) % 50 + 1);
        core1.allocateProtocolFeesToInsurance(uint256(seed) % 200 + 1);

        uint256 donated = uint256(seed) + 1;
        token.mint(address(vault), donated);
        uint256 custodyBefore = token.balanceOf(address(vault));
        uint256 accountedBefore = vault.totalAccountedCollateral();
        uint256 recipientBefore = token.balanceOf(address(this));
        uint256 fees0Before = core0.protocolFeesAccrued();
        uint256 fees1Before = core1.protocolFeesAccrued();
        uint256 insurance0Before = core0.insuranceReserves();
        uint256 insurance1Before = core1.insuranceReserves();

        // Even accrued protocol fees plus apparent ERC20 excess cannot allow
        // owner extraction from shared portfolio backing.
        (bool sweepSucceeded,) = address(vault).call(
            abi.encodeCall(vault.sweepExcess, (address(this), donated))
        );
        assertTrue(!sweepSucceeded, "shared-vault surplus was swept");
        (bool fee0Succeeded,) = address(core0).call(
            abi.encodeWithSignature("withdrawProtocolFees(address,uint256)", address(this), 1)
        );
        (bool fee1Succeeded,) = address(core1).call(
            abi.encodeWithSignature("withdrawProtocolFees(address,uint256)", address(this), 1)
        );
        assertTrue(!fee0Succeeded && !fee1Succeeded, "unproved fee payout authorized");
        assertEq(token.balanceOf(address(vault)), custodyBefore, "shared vault custody moved");
        assertEq(vault.totalAccountedCollateral(), accountedBefore, "claims changed");
        assertEq(token.balanceOf(address(this)), recipientBefore, "treasury received tokens");
        assertEq(core0.protocolFeesAccrued(), fees0Before, "first market fee changed");
        assertEq(core1.protocolFeesAccrued(), fees1Before, "second market fee changed");
        assertEq(core0.insuranceReserves(), insurance0Before, "first reserve changed");
        assertEq(core1.insuranceReserves(), insurance1Before, "second reserve changed");
    }
}

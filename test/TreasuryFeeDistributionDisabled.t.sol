// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {PortfolioTwoMarketFeeIsolationTest} from "./PortfolioTwoMarketFeeIsolation.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";

/// @notice Fee accrual is ledger-only, never a privileged payout right.
/// Neither custody implementation exposes a treasury distribution entrypoint.
contract TreasuryFeeDistributionDisabledTest is PortfolioTwoMarketFeeIsolationTest {
    function testFuzz_NoTreasuryDistributionFromPortfolioCoreOrVault(uint96 amountSeed) public {
        uint256 amount = uint256(amountSeed) + 1;
        uint256 custody = token.balanceOf(address(vault));
        uint256 accountant = vault.totalAccountedCollateral();
        uint256 treasuryBefore = token.balanceOf(address(this));
        bytes memory payload = abi.encodeWithSignature("withdrawProtocolFees(address,uint256)", address(this), amount);
        (bool coreZero,) = address(core0).call(payload);
        (bool coreOne,) = address(core1).call(payload);
        (bool sharedVault,) = address(vault).call(payload);
        assertTrue(!coreZero && !coreOne && !sharedVault, "unproved treasury payout succeeded");
        assertEq(token.balanceOf(address(vault)), custody, "treasury callback consumed vault");
        assertEq(vault.totalAccountedCollateral(), accountant, "treasury callback changed claims");
        assertEq(token.balanceOf(address(this)), treasuryBefore, "treasury acquired collateral");
    }

    function testFuzz_NoTreasuryDistributionFromStandaloneCore(uint96 amountSeed) public {
        MockERC20 asset = new MockERC20();
        OrderBookCore standalone =
            new OrderBookCore(address(asset), address(new MockMarkOracle(100)), 30, 1000, 100, 0);
        asset.mint(address(this), 1000);
        asset.approve(address(standalone), 1000);
        standalone.depositCollateral(1000);
        uint256 amount = uint256(amountSeed) + 1;
        (bool succeeded,) = address(standalone).call(
            abi.encodeWithSignature("withdrawProtocolFees(address,uint256)", address(this), amount)
        );
        assertTrue(!succeeded, "standalone fee payout unexpectedly enabled");
        assertEq(asset.balanceOf(address(standalone)), 1000, "standalone custody spent");
        assertEq(standalone.accountEquity(address(this)), int256(1000), "account claim reduced");
    }
}

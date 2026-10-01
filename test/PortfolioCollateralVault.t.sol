// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TestBase} from "./TestBase.sol";

contract PortfolioCollateralVaultTest is TestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant CONTROLLER = address(0xC011);
    address internal constant TREASURY = address(0xBEEF);

    MockERC20 internal token;
    PortfolioCollateralVault internal vault;

    function setUp() public {
        token = new MockERC20();
        vault = new PortfolioCollateralVault(address(token));

        token.mint(ALICE, 1_000_000 ether);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
    }

    function testDepositAndWithdrawPreserveCustody() public {
        vm.prank(ALICE);
        vault.deposit(1_000 ether);

        assertEq(vault.balanceOf(ALICE), 1_000 ether, "ledger mismatch");
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "custody mismatch"
        );

        vm.prank(ALICE);
        vault.withdraw(250 ether);

        assertEq(vault.balanceOf(ALICE), 750 ether, "withdraw ledger mismatch");
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "post-withdraw custody mismatch"
        );
    }

    function testLockedCollateralCannotBeWithdrawn() public {
        vault.configureController(CONTROLLER);

        vm.prank(ALICE);
        vault.deposit(1_000 ether);

        vm.prank(CONTROLLER);
        vault.setLockedCollateral(ALICE, 700 ether);

        vm.prank(ALICE);
        (bool ok,) =
            address(vault).call(abi.encodeCall(vault.withdraw, (1 ether)));
        assertTrue(!ok, "direct withdrawal bypassed portfolio controller");

        assertEq(vault.balanceOf(ALICE), 1_000 ether, "portfolio deposit changed");
        assertEq(vault.lockedCollateral(ALICE), 700 ether, "lock changed");
    }

    function testControllerCanReleaseCollateral() public {
        vault.configureController(CONTROLLER);

        vm.prank(ALICE);
        vault.deposit(1_000 ether);

        vm.prank(CONTROLLER);
        vault.setLockedCollateral(ALICE, 700 ether);

        vm.prank(CONTROLLER);
        vault.setLockedCollateral(ALICE, 200 ether);

        assertEq(vault.freeCollateral(ALICE), 800 ether, "free collateral mismatch");
    }

    function testUnauthorizedCannotChangeLock() public {
        vm.prank(ALICE);
        vault.deposit(100 ether);

        vm.prank(ALICE);
        (bool ok,) = address(vault).call(
            abi.encodeCall(vault.setLockedCollateral, (ALICE, 50 ether))
        );
        assertTrue(!ok, "unauthorized lock mutation");
        assertEq(vault.lockedCollateral(ALICE), 0, "lock mutated");
    }

    function testControllerCannotOverLock() public {
        vault.configureController(CONTROLLER);

        vm.prank(ALICE);
        vault.deposit(100 ether);

        vm.prank(CONTROLLER);
        (bool ok,) = address(vault).call(
            abi.encodeCall(vault.setLockedCollateral, (ALICE, 101 ether))
        );
        assertTrue(!ok, "over-lock accepted");
    }

    function testControllerWithdrawalCanCreateSignedProfitDebit() public {
        vault.configureController(CONTROLLER);

        vm.prank(ALICE);
        vault.deposit(100 ether);

        token.mint(TREASURY, 100 ether);
        vm.prank(TREASURY);
        token.approve(address(vault), type(uint256).max);
        vm.prank(TREASURY);
        vault.deposit(100 ether);

        vm.prank(CONTROLLER);
        vault.controllerWithdraw(ALICE, ALICE, 125 ether);

        assertEq(vault.balanceOf(ALICE), 100 ether, "gross deposit changed");
        assertEq(vault.portfolioWithdrawn(ALICE), 125 ether, "portfolio debit mismatch");
        assertEq(vault.collateralClaim(ALICE), int256(-25 ether), "signed claim mismatch");
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "controller withdrawal broke custody"
        );
    }

    function testOwnerCanSweepOnlyUnaccountedDonations() public {
        vm.prank(ALICE);
        vault.deposit(100 ether);

        token.mint(address(vault), 25 ether);
        assertEq(vault.excessTokenBalance(), 25 ether, "excess mismatch");

        vault.sweepExcess(TREASURY, 25 ether);

        assertEq(token.balanceOf(TREASURY), 25 ether, "sweep recipient mismatch");
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "accounted custody was swept"
        );
    }

    function testFuzz_LockUnlockWithdrawNeverBreaksBacking(
        uint96 depositSeed,
        uint96 lockSeed,
        uint96 withdrawSeed
    ) public {
        vault.configureController(CONTROLLER);

        uint256 amount = uint256(depositSeed % 1_000_000 ether) + 1;
        token.mint(ALICE, amount);

        vm.prank(ALICE);
        vault.deposit(amount);

        uint256 locked = uint256(lockSeed) % (amount + 1);
        vm.prank(CONTROLLER);
        vault.setLockedCollateral(ALICE, locked);

        uint256 free = amount - locked;
        uint256 withdrawn =
            free == 0 ? 0 : uint256(withdrawSeed) % (free + 1);

        if (withdrawn != 0) {
            vm.prank(CONTROLLER);
            vault.controllerWithdraw(ALICE, ALICE, withdrawn);
        }

        int256 claim = vault.collateralClaim(ALICE);
        uint256 positiveClaim = claim > 0 ? uint256(claim) : 0;
        assertTrue(
            vault.lockedCollateral(ALICE) <= positiveClaim,
            "lock exceeded positive collateral claim"
        );
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalAccountedCollateral(),
            "vault accounting exceeded custody"
        );
    }
}

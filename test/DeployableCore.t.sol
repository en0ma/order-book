// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {TestBase} from "./TestBase.sol";

contract DeployableCoreTest is TestBase {
    OrderBookCore internal core;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        core = new OrderBookCore();
        core.configureAdvancedModule(address(this));
    }

    function testDirectHotPathStillMatchesOnChain() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        uint96 filled =
            core.take(IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC);

        assertEq(filled, 40, "core direct fill mismatch");
        assertEq(int256(core.accountPosition(address(this))), 40, "taker position mismatch");
    }

    function testModuleCanReserveThenExecuteForAccount() public {
        core.configureRisk(100, 20, 1_000);

        vm.prank(ALICE);
        core.depositCollateral(100_000);
        vm.prank(BOB);
        core.depositCollateral(100_000);

        vm.prank(BOB);
        core.addLiquidity(IOrderBookCore.Side.Ask, 105, 100);

        uint16 ceiling =
            core.moduleReserveExposure(ALICE, IOrderBookCore.Side.Bid, 50);
        assertEq(ceiling, 120, "module risk ceiling");

        uint96 filled = core.moduleTake(
            ALICE,
            IOrderBookCore.Side.Bid,
            110,
            50,
            IOrderBookCore.FillPolicy.IOC,
            false,
            true
        );

        assertEq(filled, 50, "module execution mismatch");
        assertEq(int256(core.accountPosition(ALICE)), 50, "module account position");
    }

    function testModuleRestingSharesCannotBeBurnedByGenericCancel() public {
        core.configureRisk(100, 20, 1_000);

        vm.prank(ALICE);
        core.depositCollateral(100_000);

        uint16 ceiling =
            core.moduleReserveExposure(ALICE, IOrderBookCore.Side.Bid, 50);

        uint128 shares = core.moduleAddLiquidity(
            ALICE,
            IOrderBookCore.Side.Bid,
            99,
            50,
            ceiling
        );

        assertEq(
            core.moduleLockedShares(ALICE, IOrderBookCore.Side.Bid, 99),
            shares,
            "module share lock missing"
        );

        vm.prank(ALICE);
        (bool genericCancel,) = address(core).call(
            abi.encodeCall(
                core.removeShares,
                (IOrderBookCore.Side.Bid, uint16(99), shares)
            )
        );
        assertTrue(!genericCancel, "generic cancel burned module-owned shares");

        uint96 removed = core.moduleRemoveLockedShares(
            ALICE,
            IOrderBookCore.Side.Bid,
            99,
            shares
        );

        assertEq(removed, 50, "module cancellation lots");
        assertEq(
            core.moduleLockedShares(ALICE, IOrderBookCore.Side.Bid, 99),
            0,
            "module share lock remained"
        );
    }

    function testAdvancedModuleCanOnlyBeConfiguredOnce() public {
        (bool ok,) =
            address(core).call(abi.encodeCall(core.configureAdvancedModule, (address(0x1234))));
        assertTrue(!ok, "advanced module was replaceable");
    }
}

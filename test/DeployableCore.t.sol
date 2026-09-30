// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarkOracle} from "./mocks/MockMarkOracle.sol";
import {TestBase} from "./TestBase.sol";

contract DeployableCoreTest is TestBase {
    OrderBookCore internal core;
    MockERC20 internal token;
    MockMarkOracle internal oracle;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        oracle = new MockMarkOracle(100);
        core = new OrderBookCore(address(token), address(oracle), 20, 1_000);
        core.configureAdvancedModule(address(this));

        _fund(ALICE, 100_000);
        _fund(BOB, 100_000);
        _fund(address(this), 100_000);
    }

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(core), type(uint256).max);
        vm.prank(account);
        core.depositCollateral(amount);
    }

    function testDirectHotPathStillMatchesOnChain() public {
        vm.prank(ALICE);
        core.addLiquidity(IOrderBookCore.Side.Ask, 100, 100);

        uint96 filled =
            core.take(IOrderBookCore.Side.Bid, 100, 40, IOrderBookCore.FillPolicy.IOC);

        assertEq(filled, 40, "core direct fill mismatch");
        assertEq(int256(_corePosition(address(this))), 40, "taker position mismatch");
    }

    function testModuleCanReserveThenExecuteForAccount() public {
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
        assertEq(int256(_corePosition(ALICE)), 50, "module account position");
    }

    function testModuleRestingSharesCannotBeBurnedByGenericCancel() public {
        uint16 ceiling =
            core.moduleReserveExposure(ALICE, IOrderBookCore.Side.Bid, 50);

        uint128 shares = core.moduleAddLiquidity(
            ALICE,
            IOrderBookCore.Side.Bid,
            99,
            50,
            ceiling
        );

        vm.prank(ALICE);
        (bool genericCancel,) = address(core).call(
            abi.encodeCall(
                core.removeShares,
                (IOrderBookCore.Side.Bid, uint16(99), shares)
            )
        );
        assertTrue(!genericCancel, "generic cancel burned module-owned shares");

        (,, uint32 generation) = core.pools(IOrderBookCore.Side.Bid, 99);

        uint96 removed = core.moduleRemoveLockedShares(
            ALICE,
            IOrderBookCore.Side.Bid,
            99,
            generation,
            shares
        );

        assertEq(removed, 50, "module cancellation lots");

    }

    function testAdvancedModuleCanOnlyBeConfiguredOnce() public {
        (bool ok,) =
            address(core).call(abi.encodeCall(core.configureAdvancedModule, (address(0x1234))));
        assertTrue(!ok, "advanced module was replaceable");
    }
    function _corePosition(address account) internal view returns (int80 position) {
        (position,,) = core.accountRisk(account);
    }

}

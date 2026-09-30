// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProRataOrderBook} from "../src/ProRataOrderBook.sol";
import {TestBase} from "./TestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockExtremaOracle} from "./mocks/MockExtremaOracle.sol";

contract GasTest is TestBase {
    function testGas_FillCostIsIndependentOfMakerCount() public {
        ProRataOrderBook oneMaker = new ProRataOrderBook();
        ProRataOrderBook manyMakers = new ProRataOrderBook();

        vm.prank(address(0x1));
        oneMaker.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, 6_400);

        for (uint160 i = 1; i <= 64; ++i) {
            vm.prank(address(0x1000 + i));
            manyMakers.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, 100);
        }

        uint256 g0 = gasleft();
        oneMaker.take(
            ProRataOrderBook.Side.Bid, 10_000, 3_200, ProRataOrderBook.FillPolicy.IOC
        );
        uint256 oneMakerGas = g0 - gasleft();

        uint256 g1 = gasleft();
        manyMakers.take(
            ProRataOrderBook.Side.Bid, 10_000, 3_200, ProRataOrderBook.FillPolicy.IOC
        );
        uint256 manyMakerGas = g1 - gasleft();

        uint256 diff =
            oneMakerGas > manyMakerGas ? oneMakerGas - manyMakerGas : manyMakerGas - oneMakerGas;

        assertTrue(diff < 20_000, "fill gas unexpectedly scales with maker count");
        assertTrue(manyMakerGas < 250_000, "single-tick fill gas ceiling exceeded");
    }

    function testGas_CancelIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();
        address maker = address(0xBEEF);

        vm.prank(maker);
        uint128 shares = book.addLiquidity(ProRataOrderBook.Side.Bid, 20_000, 10_000);

        vm.prank(maker);
        uint256 g0 = gasleft();
        book.removeShares(ProRataOrderBook.Side.Bid, 20_000, shares);
        uint256 used = g0 - gasleft();

        assertTrue(used < 220_000, "cancel gas ceiling exceeded");
    }

    function testGas_ConditionalExecutionIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();

        vm.prank(address(0xA1));
        book.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, 1_000);

        uint64 orderId = book.placeConditionalOrder(
            ProRataOrderBook.Side.Bid,
            true,
            0,
            10_000,
            500,
            ProRataOrderBook.FillPolicy.IOC,
            false
        );

        uint256 g0 = gasleft();
        uint96 filled = book.executeConditionalOrder(orderId);
        uint256 used = g0 - gasleft();

        assertEq(filled, 500, "conditional gas fixture did not fill");
        assertTrue(used < 300_000, "conditional execution gas ceiling exceeded");
    }

    function testGas_LiquidationCloseIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();
        address account = address(0xA11CE);
        address maker = address(0xB0B);

        book.configureRisk(100, 20, 2_000);
        book.configureLiquidation(1_000);

        vm.prank(account);
        book.depositCollateral(3_000);
        vm.prank(maker);
        book.depositCollateral(100_000);

        vm.prank(maker);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 100);
        vm.prank(account);
        book.take(ProRataOrderBook.Side.Bid, 100, 100, ProRataOrderBook.FillPolicy.IOC);

        vm.prank(maker);
        book.addLiquidity(ProRataOrderBook.Side.Bid, 70, 100);
        book.setMarkTick(70);

        ProRataOrderBook.Side[] memory sides = new ProRataOrderBook.Side[](0);
        uint16[] memory ticks = new uint16[](0);
        uint64[] memory conditionals = new uint64[](0);

        uint256 g0 = gasleft();
        uint96 closed = book.liquidate(account, sides, ticks, conditionals);
        uint256 used = g0 - gasleft();

        assertEq(closed, 100, "liquidation gas fixture did not close");
        assertTrue(used < 350_000, "liquidation gas ceiling exceeded");
    }

    function testGas_TriggeredLimitActivationIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();
        address owner = address(0xA11CE);

        book.configureRisk(10_000, 100, 1_000);

        vm.prank(owner);
        book.depositCollateral(10_000_000);

        vm.prank(address(0xB0B));
        book.depositCollateral(10_000_000);
        vm.prank(address(0xB0B));
        book.addLiquidity(ProRataOrderBook.Side.Ask, 10_020, 250);

        vm.prank(owner);
        uint64 orderId = book.placeTriggeredLimitOrder(
            ProRataOrderBook.Side.Bid,
            true,
            10_000,
            10_030,
            500
        );

        uint256 g0 = gasleft();
        uint96 filled = book.executeConditionalOrder(orderId);
        uint256 used = g0 - gasleft();

        assertEq(filled, 250, "triggered-limit fixture aggressive fill mismatch");
        assertTrue(used < 450_000, "triggered-limit activation gas ceiling exceeded");
    }

    function testGas_MinimumFillIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();

        vm.prank(address(0xA1));
        book.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, 1_000);

        uint256 g0 = gasleft();
        uint96 filled =
            book.takeMinFill(ProRataOrderBook.Side.Bid, 10_000, 500, 250);
        uint256 used = g0 - gasleft();

        assertEq(filled, 500, "minimum-fill gas fixture did not fill");
        assertTrue(used < 260_000, "minimum-fill gas ceiling exceeded");
    }

    function testGas_OTOActivationIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();
        address account = address(0xA11CE);

        vm.prank(address(0xB0B));
        book.addLiquidity(ProRataOrderBook.Side.Ask, 10_000, 500);

        vm.prank(account);
        uint64 parent = book.placeConditionalOrder(
            ProRataOrderBook.Side.Bid,
            true,
            0,
            10_000,
            500,
            ProRataOrderBook.FillPolicy.IOC,
            false
        );

        vm.prank(account);
        uint64 child = book.placeConditionalOrder(
            ProRataOrderBook.Side.Ask,
            true,
            20_000,
            10_000,
            500,
            ProRataOrderBook.FillPolicy.IOC,
            true
        );

        vm.prank(account);
        book.linkOTO(parent, child);

        uint256 g0 = gasleft();
        uint96 filled = book.executeConditionalOrder(parent);
        uint256 used = g0 - gasleft();

        assertEq(filled, 500, "OTO parent gas fixture did not fill");
        assertTrue(book.conditionalOrderActive(child), "OTO child did not activate");
        assertTrue(used < 350_000, "OTO activation gas ceiling exceeded");
    }

    function testGas_TrailingExecutionIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();
        MockERC20 token = new MockERC20();
        MockExtremaOracle oracle = new MockExtremaOracle(100);
        address account = address(0xA11CE);
        address maker = address(0xB0B);
        address exitMaker = address(0xCAFE);

        book.configureSettlement(address(token), address(oracle));
        book.configureExtremaOracle(address(oracle));
        book.configureRisk(100, 40, 1_000);

        token.mint(account, 100_000);
        token.mint(maker, 100_000);
        token.mint(exitMaker, 100_000);

        vm.prank(account);
        token.approve(address(book), type(uint256).max);
        vm.prank(account);
        book.depositCollateral(100_000);

        vm.prank(maker);
        token.approve(address(book), type(uint256).max);
        vm.prank(maker);
        book.depositCollateral(100_000);

        vm.prank(exitMaker);
        token.approve(address(book), type(uint256).max);
        vm.prank(exitMaker);
        book.depositCollateral(100_000);

        vm.prank(maker);
        book.addLiquidity(ProRataOrderBook.Side.Ask, 100, 100);
        vm.prank(account);
        book.take(ProRataOrderBook.Side.Bid, 100, 100, ProRataOrderBook.FillPolicy.IOC);

        vm.prank(account);
        uint64 trailingId = book.placeTrailingOrder(
            ProRataOrderBook.Side.Ask,
            10,
            80,
            100,
            ProRataOrderBook.FillPolicy.IOC,
            true
        );

        oracle.setMarkTick(120);
        vm.prank(exitMaker);
        book.addLiquidity(ProRataOrderBook.Side.Bid, 109, 100);
        oracle.setMarkTick(109);

        uint256 g0 = gasleft();
        uint96 filled = book.executeTrailingOrder(trailingId);
        uint256 used = g0 - gasleft();

        assertEq(filled, 100, "trailing gas fixture did not fill");
        assertTrue(used < 400_000, "trailing execution gas ceiling exceeded");
    }

    function testGas_AddAtExistingTickIsBounded() public {
        ProRataOrderBook book = new ProRataOrderBook();

        vm.prank(address(0x1));
        book.addLiquidity(ProRataOrderBook.Side.Ask, 30_000, 1_000);

        vm.prank(address(0x2));
        uint256 g0 = gasleft();
        book.addLiquidity(ProRataOrderBook.Side.Ask, 30_000, 1_000);
        uint256 used = g0 - gasleft();

        assertTrue(used < 220_000, "maker add gas ceiling exceeded");
    }
}

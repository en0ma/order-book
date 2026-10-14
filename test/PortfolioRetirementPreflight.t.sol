// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PortfolioTwoMarketFeeIsolationTest} from "./PortfolioTwoMarketFeeIsolation.t.sol";
import {PortfolioRetirementPreflight} from "../src/deployable/PortfolioRetirementPreflight.sol";
import {IOrderBookCore} from "../src/deployable/IOrderBookCore.sol";

contract PortfolioRetirementPreflightTest is PortfolioTwoMarketFeeIsolationTest {
    function testLiveCollateralPreventsPortfolioRetirement() public {
        (bool ok,) = address(new PortfolioRetirementPreflight(address(coordinator))).call(
            abi.encodeCall(PortfolioRetirementPreflight.assertConfigurationAndReservesClear, ())
        );
        assertTrue(!ok, "live vault principal was ignored by retirement check");
        assertEq(vault.totalAccountedCollateral(), 130_000, "preflight changed ledger");
        assertEq(token.balanceOf(address(vault)), 130_000, "preflight spent custody");
    }

    function testFuzz_AccountClaimCannotBeOmittedByPreflight(uint16 seed) public {
        address[] memory accounts = new address[](1);
        accounts[0] = uint256(seed) % 2 == 0 ? MAKER : TAKER;
        (bool ok,) = address(new PortfolioRetirementPreflight(address(coordinator))).call(
            abi.encodeCall(PortfolioRetirementPreflight.assertAccountsClear, (accounts))
        );
        assertTrue(!ok, "live account claim was certified retired");
    }

    function testTradeExposureAndOutstandingFeesAlsoPreventRetirement() public {
        vm.prank(MAKER);
        coordinator.addLiquidity(0, IOrderBookCore.Side.Ask, 100, 100);
        vm.prank(TAKER);
        coordinator.take(0, IOrderBookCore.Side.Bid, 100, 100, IOrderBookCore.FillPolicy.IOC);

        address[] memory accounts = new address[](1);
        accounts[0] = TAKER;
        (bool clear,) = address(new PortfolioRetirementPreflight(address(coordinator))).call(
            abi.encodeCall(PortfolioRetirementPreflight.assertAccountsClear, (accounts))
        );
        assertTrue(!clear, "open portfolio exposure passed retirement preflight");
        (bool reservesClear,) = address(new PortfolioRetirementPreflight(address(coordinator))).call(
            abi.encodeCall(PortfolioRetirementPreflight.assertConfigurationAndReservesClear, ())
        );
        assertTrue(!reservesClear, "live reserves and custody passed retirement preflight");
        assertEq(core0.protocolFeesAccrued(), 50, "preflight modified fees");
    }

    function testEmptyOrDuplicateAccountInventoryNeverCertifies() public {
        address[] memory empty = new address[](0);
        (bool ok,) = address(new PortfolioRetirementPreflight(address(coordinator))).call(
            abi.encodeCall(PortfolioRetirementPreflight.assertAccountsClear, (empty))
        );
        assertTrue(!ok, "empty inventory was accepted");
        address[] memory duplicate = new address[](2);
        duplicate[0] = MAKER;
        duplicate[1] = MAKER;
        (ok,) = address(new PortfolioRetirementPreflight(address(coordinator))).call(
            abi.encodeCall(PortfolioRetirementPreflight.assertAccountsClear, (duplicate))
        );
        assertTrue(!ok, "duplicate inventory was accepted");
    }
}

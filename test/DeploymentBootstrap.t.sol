// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {DeployStandalone} from "../script/DeployStandalone.s.sol";
import {SegmentTreeExtremaOracle} from "../src/SegmentTreeExtremaOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeploymentBootstrapTest is TestBase {
    address internal constant ADMIN = address(0xAD11);
    address internal constant NEXT_ADMIN = address(0xBEEF);

    function testStandaloneBootstrapWiresSelfHostedStack() public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        DeployStandalone deployer = new DeployStandalone();

        DeployStandalone.Config memory config = DeployStandalone.Config({
            protocolAdmin: ADMIN,
            collateralToken: address(token),
            oracle: address(oracle),
            executionBandTicks: 40,
            initialMarginBps: 1_000,
            maintenanceMarginBps: 500,
            takerFeeBps: 5,
            makerRebateBps: 2,
            liquidatorRewardBps: 25,
            collateralUnitsPerLotTick: 1_000
        });

        DeployStandalone.Deployment memory deployed =
            deployer.deployStandalone(config);

        assertTrue(
            deployed.core.advancedModule() == address(deployed.advanced),
            "core advanced wiring"
        );
        assertTrue(
            deployed.advanced.marketMakerModule() == address(deployed.marketMaker),
            "advanced MM wiring"
        );
        assertTrue(
            deployed.advanced.liquidationModule() == address(deployed.liquidation),
            "advanced liquidation wiring"
        );
        assertTrue(
            address(deployed.marketMaker.core()) == address(deployed.core),
            "MM core wiring"
        );
        assertTrue(
            address(deployed.marketMaker.gateway()) == address(deployed.advanced),
            "MM gateway wiring"
        );
        assertTrue(
            address(deployed.liquidation.core()) == address(deployed.core),
            "liquidation core wiring"
        );
        assertTrue(
            address(deployed.liquidation.gateway()) == address(deployed.advanced),
            "liquidation gateway wiring"
        );
        assertEq(
            uint256(deployed.liquidation.maintenanceMarginBps()),
            500,
            "maintenance margin"
        );
        assertEq(
            uint256(deployed.liquidation.liquidatorRewardBps()),
            25,
            "liquidator reward"
        );
        assertEq(
            deployed.core.notionalValue(2, 3),
            6_000,
            "accounting scale"
        );
        assertTrue(
            address(deployed.lens.core()) == address(deployed.core),
            "lens core wiring"
        );
        assertTrue(
            address(deployed.lens.advanced()) == address(deployed.advanced),
            "lens advanced wiring"
        );
        assertTrue(
            deployed.core.fundingUpdater() == ADMIN,
            "funding updater not handed off"
        );

        vm.prank(ADMIN);
        deployed.core.setFundingUpdater(NEXT_ADMIN);
        assertTrue(
            deployed.core.fundingUpdater() == NEXT_ADMIN,
            "core ownership not handed off"
        );

        vm.prank(ADMIN);
        deployed.advanced.transferOwnership(NEXT_ADMIN);

        vm.prank(ADMIN);
        deployed.liquidation.transferOwnership(NEXT_ADMIN);
    }
}

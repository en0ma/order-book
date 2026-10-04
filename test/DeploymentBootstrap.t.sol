// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {DeployStandalone} from "../script/DeployStandalone.s.sol";
import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
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
        assertTrue(deployed.core.owner() == ADMIN, "core owner not handed off");
        assertTrue(
            deployed.advanced.owner() == ADMIN,
            "advanced owner not handed off"
        );
        assertTrue(
            deployed.liquidation.owner() == ADMIN,
            "liquidation owner not handed off"
        );
        assertTrue(
            deployed.core.fundingUpdater() == ADMIN,
            "funding updater not handed off"
        );

        vm.prank(address(deployer));
        (bool oldCoreOwnerOk,) = address(deployed.core).call(
            abi.encodeCall(deployed.core.setFundingUpdater, (NEXT_ADMIN))
        );
        assertTrue(!oldCoreOwnerOk, "deployer retained core admin");

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

    function testRejectsZeroProtocolAdminBeforeDeployment() public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        DeployStandalone deployer = new DeployStandalone();

        DeployStandalone.Config memory config = DeployStandalone.Config({
            protocolAdmin: address(0),
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

        (bool ok,) = address(deployer).call(
            abi.encodeCall(deployer.deployStandalone, (config))
        );
        assertTrue(!ok, "zero admin deployment accepted");
    }

    function testPortfolioAdminSurfacesSupportSafeHandoff() public {
        MockERC20 token = new MockERC20();
        SegmentTreeExtremaOracle oracle =
            new SegmentTreeExtremaOracle(address(this), 100, 3_600);
        OrderBookCore core =
            new OrderBookCore(address(token), address(oracle), 40, 1_000, 0, 0);

        PortfolioMarginPolicy.MarketInput[] memory markets =
            new PortfolioMarginPolicy.MarketInput[](1);
        markets[0] = PortfolioMarginPolicy.MarketInput({
            core: address(core),
            riskGroup: 1,
            marginBps: 1_000,
            hedgeCreditBps: 0
        });

        PortfolioMarginPolicy policy = new PortfolioMarginPolicy(markets);
        PortfolioCollateralVault vault =
            new PortfolioCollateralVault(address(token));

        policy.transferOwnership(ADMIN);
        vault.transferOwnership(ADMIN);

        assertTrue(policy.owner() == ADMIN, "policy admin handoff");
        assertTrue(vault.owner() == ADMIN, "vault admin handoff");

        (bool oldPolicyOwnerOk,) = address(policy).call(
            abi.encodeCall(policy.configureSharedCollateralVault, (address(vault)))
        );
        assertTrue(!oldPolicyOwnerOk, "deployer retained policy admin");

        vm.prank(ADMIN);
        policy.configureSharedCollateralVault(address(vault));
        assertTrue(
            address(policy.sharedCollateralVault()) == address(vault),
            "policy admin cannot configure vault"
        );

        vm.prank(ADMIN);
        vault.configureController(NEXT_ADMIN);
        assertTrue(vault.controller() == NEXT_ADMIN, "vault admin cannot configure");
    }
}

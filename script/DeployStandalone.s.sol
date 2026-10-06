// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {ExecutionStrategyModule} from "../src/deployable/ExecutionStrategyModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {LiquidationModule} from "../src/deployable/LiquidationModule.sol";
import {IntegrationLens} from "../src/deployable/IntegrationLens.sol";

interface VmDeploy {
    function envAddress(string calldata name) external returns (address value);
    function envUint(string calldata name) external returns (uint256 value);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @notice Foundry deployment script for a single standalone market.
/// @dev Run with forge script and --broadcast. The broadcaster performs deployment
///      and one-time wiring, then long-lived admin authority moves to protocolAdmin.
contract DeployStandalone {
    error InvalidDeploymentConfig();

    VmDeploy internal constant vm =
        VmDeploy(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Config {
        address protocolAdmin;
        address fundingUpdater;
        address collateralToken;
        address oracle;
        uint16 executionBandTicks;
        uint16 initialMarginBps;
        uint16 maintenanceMarginBps;
        uint16 takerFeeBps;
        uint16 makerRebateBps;
        uint16 liquidatorRewardBps;
        uint128 collateralUnitsPerLotTick;
    }

    struct Deployment {
        OrderBookCore core;
        AdvancedOrderModule advanced;
        ExecutionStrategyModule strategy;
        MarketMakerModule marketMaker;
        LiquidationModule liquidation;
        IntegrationLens lens;
    }

    event StandaloneStackDeployed(
        address indexed core,
        address indexed advanced,
        address indexed marketMaker,
        address strategy,
        address liquidation,
        address lens,
        address collateralToken,
        address oracle,
        address protocolAdmin,
        address fundingUpdater
    );

    function run() external returns (Deployment memory deployment) {
        Config memory config = Config({
            protocolAdmin: vm.envAddress("PROTOCOL_ADMIN"),
            fundingUpdater: vm.envAddress("FUNDING_UPDATER"),
            collateralToken: vm.envAddress("COLLATERAL_TOKEN"),
            oracle: vm.envAddress("MARK_ORACLE"),
            executionBandTicks: _envUint16("EXECUTION_BAND_TICKS"),
            initialMarginBps: _envUint16("INITIAL_MARGIN_BPS"),
            maintenanceMarginBps: _envUint16("MAINTENANCE_MARGIN_BPS"),
            takerFeeBps: _envUint16("TAKER_FEE_BPS"),
            makerRebateBps: _envUint16("MAKER_REBATE_BPS"),
            liquidatorRewardBps: _envUint16("LIQUIDATOR_REWARD_BPS"),
            collateralUnitsPerLotTick: _envUint128("COLLATERAL_UNITS_PER_LOT_TICK")
        });

        _validateConfig(config);

        vm.startBroadcast();
        deployment = deployStandalone(config);
        vm.stopBroadcast();
    }

    function deployStandalone(Config memory config)
        public
        returns (Deployment memory deployment)
    {
        _validateConfig(config);

        deployment.core = new OrderBookCore(
            config.collateralToken,
            config.oracle,
            config.executionBandTicks,
            config.initialMarginBps,
            config.takerFeeBps,
            config.makerRebateBps
        );
        deployment.advanced =
            new AdvancedOrderModule(address(deployment.core), config.oracle);
        deployment.strategy = new ExecutionStrategyModule(
            address(deployment.core), address(deployment.advanced)
        );
        deployment.marketMaker = new MarketMakerModule(
            address(deployment.core), address(deployment.advanced)
        );
        deployment.liquidation = new LiquidationModule(
            address(deployment.core),
            address(deployment.advanced),
            config.maintenanceMarginBps
        );
        deployment.lens =
            new IntegrationLens(address(deployment.core), address(deployment.advanced));

        deployment.core.configureAccountingUnitScale(
            config.collateralUnitsPerLotTick
        );
        deployment.core.configureAdvancedModule(address(deployment.advanced));
        deployment.advanced.configureMarketMakerModule(
            address(deployment.marketMaker)
        );
        deployment.advanced.configureExecutionStrategyModule(
            address(deployment.strategy)
        );
        deployment.advanced.configureLiquidationModule(
            address(deployment.liquidation)
        );
        deployment.liquidation.configureLiquidatorReward(
            config.liquidatorRewardBps
        );

        deployment.core.setFundingUpdater(config.fundingUpdater);
        deployment.core.transferOwnership(config.protocolAdmin);
        deployment.advanced.transferOwnership(config.protocolAdmin);
        deployment.liquidation.transferOwnership(config.protocolAdmin);

        emit StandaloneStackDeployed(
            address(deployment.core),
            address(deployment.advanced),
            address(deployment.marketMaker),
            address(deployment.strategy),
            address(deployment.liquidation),
            address(deployment.lens),
            config.collateralToken,
            config.oracle,
            config.protocolAdmin,
            config.fundingUpdater
        );
    }

    function _validateConfig(Config memory config) internal pure {
        if (
            config.protocolAdmin == address(0)
                || config.fundingUpdater == address(0)
                || config.collateralToken == address(0)
                || config.oracle == address(0)
                || config.initialMarginBps == 0
                || config.initialMarginBps > 10_000
                || config.maintenanceMarginBps == 0
                || config.maintenanceMarginBps >= config.initialMarginBps
                || config.takerFeeBps > 10_000
                || config.makerRebateBps > config.takerFeeBps
                || config.liquidatorRewardBps > 1_000
                || config.collateralUnitsPerLotTick == 0
        ) revert InvalidDeploymentConfig();
    }

    function _envUint16(string memory name) internal returns (uint16 value) {
        uint256 raw = vm.envUint(name);
        if (raw > type(uint16).max) revert InvalidDeploymentConfig();
        value = uint16(raw);
    }

    function _envUint128(string memory name) internal returns (uint128 value) {
        uint256 raw = vm.envUint(name);
        if (raw == 0 || raw > type(uint128).max) revert InvalidDeploymentConfig();
        value = uint128(raw);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
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
/// @dev Run with forge script and --broadcast. Contract ownership is assigned
///      to the broadcaster because CREATE transactions are broadcast directly.
contract DeployStandalone {
    VmDeploy internal constant vm =
        VmDeploy(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Config {
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
        MarketMakerModule marketMaker;
        LiquidationModule liquidation;
        IntegrationLens lens;
    }

    event StandaloneStackDeployed(
        address indexed core,
        address indexed advanced,
        address indexed marketMaker,
        address liquidation,
        address lens,
        address collateralToken,
        address oracle
    );

    function run() external returns (Deployment memory deployment) {
        Config memory config = Config({
            collateralToken: vm.envAddress("COLLATERAL_TOKEN"),
            oracle: vm.envAddress("MARK_ORACLE"),
            executionBandTicks: uint16(vm.envUint("EXECUTION_BAND_TICKS")),
            initialMarginBps: uint16(vm.envUint("INITIAL_MARGIN_BPS")),
            maintenanceMarginBps: uint16(vm.envUint("MAINTENANCE_MARGIN_BPS")),
            takerFeeBps: uint16(vm.envUint("TAKER_FEE_BPS")),
            makerRebateBps: uint16(vm.envUint("MAKER_REBATE_BPS")),
            liquidatorRewardBps: uint16(vm.envUint("LIQUIDATOR_REWARD_BPS")),
            collateralUnitsPerLotTick: uint128(vm.envUint("COLLATERAL_UNITS_PER_LOT_TICK"))
        });

        vm.startBroadcast();
        deployment = deployStandalone(config);
        vm.stopBroadcast();
    }

    function deployStandalone(Config memory config)
        public
        returns (Deployment memory deployment)
    {
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
        deployment.advanced.configureLiquidationModule(
            address(deployment.liquidation)
        );
        deployment.liquidation.configureLiquidatorReward(
            config.liquidatorRewardBps
        );

        emit StandaloneStackDeployed(
            address(deployment.core),
            address(deployment.advanced),
            address(deployment.marketMaker),
            address(deployment.liquidation),
            address(deployment.lens),
            config.collateralToken,
            config.oracle
        );
    }
}

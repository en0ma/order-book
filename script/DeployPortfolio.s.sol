// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderBookCore} from "../src/deployable/OrderBookCore.sol";
import {AdvancedOrderModule} from "../src/deployable/AdvancedOrderModule.sol";
import {MarketMakerModule} from "../src/deployable/MarketMakerModule.sol";
import {IntegrationLens} from "../src/deployable/IntegrationLens.sol";
import {PortfolioMarginPolicy} from "../src/deployable/PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "../src/deployable/PortfolioCollateralVault.sol";
import {PortfolioAdmissionCoordinator} from "../src/deployable/PortfolioAdmissionCoordinator.sol";
import {PortfolioLiquidationModule} from "../src/deployable/PortfolioLiquidationModule.sol";

interface VmDeployPortfolio {
    function envAddress(string calldata name) external returns (address value);
    function envAddress(string calldata name, string calldata delimiter)
        external
        returns (address[] memory values);
    function envUint(string calldata name, string calldata delimiter)
        external
        returns (uint256[] memory values);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @notice Reference bootstrap for a self-hosted multi-market portfolio deployment.
/// @dev Each market receives an independent execution stack while collateral, portfolio
///      admission and liquidation are coordinated across the configured market set.
contract DeployPortfolio {
    uint256 internal constant MAX_MARKETS = 32;

    error InvalidDeploymentConfig();

    VmDeployPortfolio internal constant vm =
        VmDeployPortfolio(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Config {
        address protocolAdmin;
        address collateralToken;
        address[] fundingUpdaters;
        address[] oracles;
        uint16[] executionBandTicks;
        uint16[] initialMarginBps;
        uint16[] takerFeeBps;
        uint16[] makerRebateBps;
        uint128[] collateralUnitsPerLotTick;
        uint32[] riskGroups;
        uint16[] portfolioMarginBps;
        uint16[] hedgeCreditBps;
    }

    struct MarketDeployment {
        OrderBookCore core;
        AdvancedOrderModule advanced;
        MarketMakerModule marketMaker;
        IntegrationLens lens;
    }

    struct Deployment {
        MarketDeployment[] markets;
        PortfolioMarginPolicy policy;
        PortfolioCollateralVault vault;
        PortfolioAdmissionCoordinator coordinator;
        PortfolioLiquidationModule liquidation;
    }

    event PortfolioStackDeployed(
        address indexed policy,
        address indexed vault,
        address indexed coordinator,
        address liquidation,
        address collateralToken,
        address protocolAdmin,
        uint256 marketCount
    );

    event PortfolioMarketDeployed(
        uint256 indexed marketIndex,
        address indexed core,
        address indexed advanced,
        address marketMaker,
        address lens,
        address oracle,
        address fundingUpdater
    );

    function run() external returns (Deployment memory deployment) {
        uint256[] memory executionBandRaw =
            vm.envUint("EXECUTION_BAND_TICKS", ",");
        uint256[] memory initialMarginRaw =
            vm.envUint("INITIAL_MARGIN_BPS", ",");
        uint256[] memory takerFeeRaw = vm.envUint("TAKER_FEE_BPS", ",");
        uint256[] memory makerRebateRaw = vm.envUint("MAKER_REBATE_BPS", ",");
        uint256[] memory accountingScaleRaw =
            vm.envUint("COLLATERAL_UNITS_PER_LOT_TICK", ",");
        uint256[] memory riskGroupRaw = vm.envUint("RISK_GROUPS", ",");
        uint256[] memory portfolioMarginRaw =
            vm.envUint("PORTFOLIO_MARGIN_BPS", ",");
        uint256[] memory hedgeCreditRaw =
            vm.envUint("HEDGE_CREDIT_BPS", ",");

        Config memory config = Config({
            protocolAdmin: vm.envAddress("PROTOCOL_ADMIN"),
            collateralToken: vm.envAddress("COLLATERAL_TOKEN"),
            fundingUpdaters: vm.envAddress("FUNDING_UPDATERS", ","),
            oracles: vm.envAddress("MARK_ORACLES", ","),
            executionBandTicks: _toUint16(executionBandRaw),
            initialMarginBps: _toUint16(initialMarginRaw),
            takerFeeBps: _toUint16(takerFeeRaw),
            makerRebateBps: _toUint16(makerRebateRaw),
            collateralUnitsPerLotTick: _toUint128(accountingScaleRaw),
            riskGroups: _toUint32(riskGroupRaw),
            portfolioMarginBps: _toUint16(portfolioMarginRaw),
            hedgeCreditBps: _toUint16(hedgeCreditRaw)
        });

        _validateConfig(config);

        vm.startBroadcast();
        deployment = deployPortfolio(config);
        vm.stopBroadcast();
    }

    function deployPortfolio(Config memory config)
        public
        returns (Deployment memory deployment)
    {
        _validateConfig(config);

        uint256 length = config.oracles.length;
        deployment.markets = new MarketDeployment[](length);

        PortfolioMarginPolicy.MarketInput[] memory policyInputs =
            new PortfolioMarginPolicy.MarketInput[](length);
        PortfolioAdmissionCoordinator.MarketInput[] memory admissionInputs =
            new PortfolioAdmissionCoordinator.MarketInput[](length);
        PortfolioLiquidationModule.MarketInput[] memory liquidationInputs =
            new PortfolioLiquidationModule.MarketInput[](length);

        for (uint256 i; i < length; ++i) {
            OrderBookCore core = new OrderBookCore(
                config.collateralToken,
                config.oracles[i],
                config.executionBandTicks[i],
                config.initialMarginBps[i],
                config.takerFeeBps[i],
                config.makerRebateBps[i]
            );
            AdvancedOrderModule advanced =
                new AdvancedOrderModule(address(core), config.oracles[i]);
            MarketMakerModule marketMaker =
                new MarketMakerModule(address(core), address(advanced));
            IntegrationLens lens =
                new IntegrationLens(address(core), address(advanced));

            deployment.markets[i] = MarketDeployment({
                core: core,
                advanced: advanced,
                marketMaker: marketMaker,
                lens: lens
            });

            policyInputs[i] = PortfolioMarginPolicy.MarketInput({
                core: address(core),
                riskGroup: config.riskGroups[i],
                marginBps: config.portfolioMarginBps[i],
                hedgeCreditBps: config.hedgeCreditBps[i]
            });
            admissionInputs[i] = PortfolioAdmissionCoordinator.MarketInput({
                core: address(core),
                gateway: address(advanced)
            });
            liquidationInputs[i] = PortfolioLiquidationModule.MarketInput({
                core: address(core),
                gateway: address(advanced)
            });
        }

        deployment.policy = new PortfolioMarginPolicy(policyInputs);
        deployment.vault =
            new PortfolioCollateralVault(config.collateralToken);
        deployment.coordinator = new PortfolioAdmissionCoordinator(
            address(deployment.policy),
            address(deployment.vault),
            admissionInputs
        );
        deployment.liquidation = new PortfolioLiquidationModule(
            address(deployment.policy),
            liquidationInputs
        );

        deployment.vault.configureController(address(deployment.coordinator));
        deployment.policy.configureSharedCollateralVault(address(deployment.vault));

        for (uint256 i; i < length; ++i) {
            MarketDeployment memory market = deployment.markets[i];

            market.core.configureAccountingUnitScale(
                config.collateralUnitsPerLotTick[i]
            );
            market.core.configureAdvancedModule(address(market.advanced));
            market.core.configurePortfolioController(address(deployment.coordinator));

            market.advanced.configureMarketMakerModule(address(market.marketMaker));
            market.advanced.configurePortfolioController(
                address(deployment.coordinator), uint8(i)
            );
            market.advanced.configureLiquidationModule(
                address(deployment.liquidation)
            );

            market.core.setFundingUpdater(config.fundingUpdaters[i]);

            emit PortfolioMarketDeployed(
                i,
                address(market.core),
                address(market.advanced),
                address(market.marketMaker),
                address(market.lens),
                config.oracles[i],
                config.fundingUpdaters[i]
            );

            market.core.transferOwnership(config.protocolAdmin);
            market.advanced.transferOwnership(config.protocolAdmin);
        }

        deployment.policy.transferOwnership(config.protocolAdmin);
        deployment.vault.transferOwnership(config.protocolAdmin);

        emit PortfolioStackDeployed(
            address(deployment.policy),
            address(deployment.vault),
            address(deployment.coordinator),
            address(deployment.liquidation),
            config.collateralToken,
            config.protocolAdmin,
            length
        );
    }

    function _validateConfig(Config memory config) internal pure {
        uint256 length = config.oracles.length;
        if (
            config.protocolAdmin == address(0)
                || config.collateralToken == address(0)
                || length == 0
                || length > MAX_MARKETS
                || length > type(uint8).max
                || config.fundingUpdaters.length != length
                || config.executionBandTicks.length != length
                || config.initialMarginBps.length != length
                || config.takerFeeBps.length != length
                || config.makerRebateBps.length != length
                || config.collateralUnitsPerLotTick.length != length
                || config.riskGroups.length != length
                || config.portfolioMarginBps.length != length
                || config.hedgeCreditBps.length != length
        ) revert InvalidDeploymentConfig();

        for (uint256 i; i < length; ++i) {
            if (
                config.fundingUpdaters[i] == address(0)
                    || config.oracles[i] == address(0)
                    || config.initialMarginBps[i] == 0
                    || config.initialMarginBps[i] > 10_000
                    || config.takerFeeBps[i] > 10_000
                    || config.makerRebateBps[i] > config.takerFeeBps[i]
                    || config.collateralUnitsPerLotTick[i] == 0
                    || config.riskGroups[i] == 0
                    || config.portfolioMarginBps[i] == 0
                    || config.portfolioMarginBps[i] > 10_000
                    || config.hedgeCreditBps[i] > 10_000
            ) revert InvalidDeploymentConfig();

            for (uint256 j; j < i; ++j) {
                if (
                    config.riskGroups[j] == config.riskGroups[i]
                        && config.hedgeCreditBps[j] != config.hedgeCreditBps[i]
                ) revert InvalidDeploymentConfig();
            }
        }
    }

    function _toUint16(uint256[] memory raw)
        internal
        pure
        returns (uint16[] memory values)
    {
        values = new uint16[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] > type(uint16).max) revert InvalidDeploymentConfig();
            values[i] = uint16(raw[i]);
        }
    }

    function _toUint32(uint256[] memory raw)
        internal
        pure
        returns (uint32[] memory values)
    {
        values = new uint32[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] > type(uint32).max) revert InvalidDeploymentConfig();
            values[i] = uint32(raw[i]);
        }
    }

    function _toUint128(uint256[] memory raw)
        internal
        pure
        returns (uint128[] memory values)
    {
        values = new uint128[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == 0 || raw[i] > type(uint128).max) {
                revert InvalidDeploymentConfig();
            }
            values[i] = uint128(raw[i]);
        }
    }
}

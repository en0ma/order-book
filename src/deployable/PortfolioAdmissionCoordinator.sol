// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {PortfolioMarginPolicy} from "./PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "./PortfolioCollateralVault.sol";

/// @title PortfolioAdmissionCoordinator
/// @notice Sole risk-increasing execution gateway for portfolio-mode markets.
/// @dev Executes first, then atomically synchronizes the vault lock to portfolio health.
///      Any insufficient collateral reverts the entire market mutation.
contract PortfolioAdmissionCoordinator {
    uint256 public constant MAX_MARKETS = 32;

    struct MarketInput {
        address core;
        address gateway;
    }

    struct MarketConfig {
        IOrderBookCore core;
        address gateway;
    }

    error InvalidPortfolioAdmissionConfig();
    error UnauthorizedGateway();
    error InsufficientPortfolioCollateral();

    PortfolioMarginPolicy public immutable policy;
    PortfolioCollateralVault public immutable vault;
    MarketConfig[] public markets;

    event PortfolioLockSynchronized(
        address indexed account,
        int256 equity,
        uint256 requirement,
        uint256 lockedCollateral
    );

    constructor(
        address policy_,
        address vault_,
        MarketInput[] memory configs
    ) {
        if (policy_ == address(0) || vault_ == address(0)) {
            revert InvalidPortfolioAdmissionConfig();
        }
        if (configs.length == 0 || configs.length > MAX_MARKETS) {
            revert InvalidPortfolioAdmissionConfig();
        }

        PortfolioMarginPolicy policyRef = PortfolioMarginPolicy(policy_);
        if (policyRef.marketCount() != configs.length) {
            revert InvalidPortfolioAdmissionConfig();
        }

        for (uint256 i; i < configs.length; ++i) {
            MarketInput memory input = configs[i];
            if (input.core == address(0) || input.gateway == address(0)) {
                revert InvalidPortfolioAdmissionConfig();
            }

            (IOrderBookCore policyCore,,,) = policyRef.markets(i);
            if (address(policyCore) != input.core) {
                revert InvalidPortfolioAdmissionConfig();
            }

            markets.push(
                MarketConfig({
                    core: IOrderBookCore(input.core),
                    gateway: input.gateway
                })
            );
        }

        policy = policyRef;
        vault = PortfolioCollateralVault(vault_);
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function syncAccount(address account)
        public
        returns (uint256 lockedCollateral)
    {
        if (
            address(policy.sharedCollateralVault()) != address(vault)
                || vault.controller() != address(this)
        ) {
            revert InvalidPortfolioAdmissionConfig();
        }

        int256 equity = policy.portfolioEquity(account);
        uint256 requirement = policy.portfolioRequirement(account);
        if (requirement > uint256(type(int256).max)) {
            revert InsufficientPortfolioCollateral();
        }
        if (equity < int256(requirement)) {
            revert InsufficientPortfolioCollateral();
        }

        uint256 balance = vault.balanceOf(account);
        uint256 withdrawable = uint256(equity - int256(requirement));
        if (withdrawable > balance) withdrawable = balance;

        lockedCollateral = balance - withdrawable;
        vault.setLockedCollateral(account, lockedCollateral);

        emit PortfolioLockSynchronized(
            account,
            equity,
            requirement,
            lockedCollateral
        );
    }

    function take(
        uint256 marketIndex,
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 lots,
        IOrderBookCore.FillPolicy fillPolicy
    ) external returns (uint96 filledLots) {
        MarketConfig storage market = _market(marketIndex);
        filledLots = market.core.portfolioTake(
            msg.sender,
            side,
            limitTick,
            lots,
            fillPolicy,
            false,
            false
        );
        syncAccount(msg.sender);
    }

    function addLiquidity(
        uint256 marketIndex,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots
    ) external returns (uint128 mintedShares) {
        MarketConfig storage market = _market(marketIndex);
        uint16 ceiling =
            market.core.portfolioReserveExposure(msg.sender, side, lots);
        mintedShares = market.core.portfolioAddLiquidity(
            msg.sender,
            side,
            tick,
            lots,
            ceiling
        );
        syncAccount(msg.sender);
    }

    function gatewayReserveExposure(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) external returns (uint16 riskCeilingTick) {
        MarketConfig storage market = _gatewayMarket(marketIndex);
        riskCeilingTick =
            market.core.portfolioReserveExposure(account, side, lots);
        syncAccount(account);
    }

    function gatewayReleaseExposure(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) external {
        MarketConfig storage market = _gatewayMarket(marketIndex);
        market.core.portfolioReleaseExposure(account, side, lots);
        syncAccount(account);
    }

    function gatewayTake(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 lots,
        IOrderBookCore.FillPolicy fillPolicy,
        bool reduceOnly,
        bool preReserved
    ) external returns (uint96 filledLots) {
        MarketConfig storage market = _gatewayMarket(marketIndex);
        filledLots = market.core.portfolioTake(
            account,
            side,
            limitTick,
            lots,
            fillPolicy,
            reduceOnly,
            preReserved
        );
        syncAccount(account);
    }

    function gatewayAddLiquidity(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots,
        uint16 reservedRiskCeiling
    ) external returns (uint128 mintedShares) {
        MarketConfig storage market = _gatewayMarket(marketIndex);
        mintedShares = market.core.portfolioAddLiquidity(
            account,
            side,
            tick,
            lots,
            reservedRiskCeiling
        );
        syncAccount(account);
    }

    function _market(uint256 marketIndex)
        internal
        view
        returns (MarketConfig storage market)
    {
        if (marketIndex >= markets.length) revert InvalidPortfolioAdmissionConfig();
        market = markets[marketIndex];
        if (market.core.portfolioController() != address(this)) {
            revert InvalidPortfolioAdmissionConfig();
        }
    }

    function _gatewayMarket(uint256 marketIndex)
        internal
        view
        returns (MarketConfig storage market)
    {
        market = _market(marketIndex);
        if (msg.sender != market.gateway) revert UnauthorizedGateway();
    }
}

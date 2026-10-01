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
    error SettlementModuleAlreadyConfigured();

    address public immutable owner;
    address public settlementModule;
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
        owner = msg.sender;
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

    function configureSettlementModule(address module) external {
        if (msg.sender != owner || module == address(0)) {
            revert InvalidPortfolioAdmissionConfig();
        }
        if (settlementModule != address(0)) {
            revert SettlementModuleAlreadyConfigured();
        }
        settlementModule = module;
    }

    function creditSystemClaim(address account, uint256 amount) external {
        if (msg.sender != settlementModule || msg.sender == address(0)) {
            revert UnauthorizedGateway();
        }
        vault.controllerCreditClaim(account, amount);
    }

    function settledCashEquity(address account) public view returns (int256 cashEquity) {
        cashEquity = vault.collateralClaim(account);

        for (uint256 i; i < markets.length; ++i) {
            IOrderBookCore core = markets[i].core;
            (int80 position,,) = core.accountRisk(account);
            int256 markedPositionValue;

            if (position != 0) {
                uint96 absLots = position > 0
                    ? uint96(uint80(position))
                    : uint96(uint256(-int256(position)));
                int256 marked =
                    int256(core.notionalValue(absLots, core.currentMarkTick()));
                markedPositionValue = position > 0 ? marked : -marked;
            }

            cashEquity += core.accountMarketValue(account) - markedPositionValue;
        }
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert InsufficientPortfolioCollateral();

        int256 cashEquity = settledCashEquity(msg.sender);
        if (
            cashEquity <= 0 || amount > uint256(cashEquity)
        ) revert InsufficientPortfolioCollateral();

        vault.controllerWithdraw(msg.sender, msg.sender, amount);
        syncAccount(msg.sender);
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

        int256 claim = vault.collateralClaim(account);
        uint256 positiveClaim = claim > 0 ? uint256(claim) : 0;
        uint256 withdrawable = uint256(equity - int256(requirement));
        if (withdrawable > positiveClaim) withdrawable = positiveClaim;

        lockedCollateral = positiveClaim - withdrawable;
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
        filledLots = market.core.moduleTake(
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
            market.core.moduleReserveExposure(msg.sender, side, lots);
        mintedShares = market.core.moduleAddLiquidity(
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
            market.core.moduleReserveExposure(account, side, lots);
        syncAccount(account);
    }

    function gatewayReleaseExposure(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) external {
        MarketConfig storage market = _gatewayMarket(marketIndex);
        market.core.moduleReleaseExposure(account, side, lots);
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
        filledLots = market.core.moduleTake(
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
        mintedShares = market.core.moduleAddLiquidity(
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

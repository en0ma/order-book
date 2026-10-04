// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {PortfolioMarginPolicy} from "./PortfolioMarginPolicy.sol";
import {PortfolioCollateralVault} from "./PortfolioCollateralVault.sol";
import {ILiquidationGateway} from "./ILiquidationGateway.sol";

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
        if (cashEquity < int256(amount)) {
            revert InsufficientPortfolioCollateral();
        }

        vault.controllerWithdraw(msg.sender, msg.sender, amount);
        syncAccount(msg.sender);
    }

    function coverBadDebt(address account)
        external
        returns (uint256 totalCovered)
    {
        int256 equity = policy.portfolioEquity(account);
        if (equity >= 0) return 0;

        uint256 length = markets.length;
        for (uint256 i; i < length; ++i) {
            MarketConfig storage market = markets[i];
            (int80 position,,) = market.core.accountRisk(account);
            if (
                position != 0 || market.core.activeQuoteCount(account) != 0
                    || ILiquidationGateway(market.gateway).activeAdvancedOrders(account) != 0
            ) revert InsufficientPortfolioCollateral();
        }

        uint256 debt = uint256(-equity);
        for (uint256 i; i < length && debt != 0; ++i) {
            uint256 covered = markets[i].core.moduleCoverBadDebt(account, debt);
            totalCovered += covered;
            debt -= covered;
        }
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
        if (requirement > uint256(type(int256).max) || equity < int256(requirement)) {
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
        IOrderBookCore core = _core(marketIndex);
        filledLots = core.moduleTake(
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
        IOrderBookCore core = _core(marketIndex);
        uint16 ceiling =
            core.moduleReserveExposure(msg.sender, side, lots);
        mintedShares = core.moduleAddLiquidity(
            msg.sender,
            side,
            tick,
            lots,
            ceiling
        );
        syncAccount(msg.sender);
    }

    function removeLiquidity(
        uint256 marketIndex,
        IOrderBookCore.Side side,
        uint16 tick,
        uint32 generation,
        uint128 shares
    ) external returns (uint96 removedLots) {
        IOrderBookCore core = _core(marketIndex);
        (uint128 quoteShares,, uint32 quoteGeneration) =
            core.quotes(msg.sender, side, tick);
        if (
            shares == 0 || shares > quoteShares
                || generation != quoteGeneration
        ) revert InvalidPortfolioAdmissionConfig();

        core.moduleSettle(msg.sender, side, tick);

        (uint128 liveShares,,) = core.quotes(msg.sender, side, tick);
        if (liveShares == 0) {
            core.moduleUnlockShares(
                msg.sender,
                side,
                tick,
                generation,
                quoteShares
            );
        } else {
            removedLots = core.moduleRemoveLockedShares(
                msg.sender,
                side,
                tick,
                generation,
                shares
            );
        }
        syncAccount(msg.sender);
    }

    function gatewayReserveExposure(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) external returns (uint16 riskCeilingTick) {
        IOrderBookCore core = _gatewayCore(marketIndex);
        riskCeilingTick =
            core.moduleReserveExposure(account, side, lots);
        syncAccount(account);
    }

    function gatewayReleaseExposure(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) external {
        IOrderBookCore core = _gatewayCore(marketIndex);
        core.moduleReleaseExposure(account, side, lots);
        syncAccount(account);
    }

    /// @notice Risk-decreasing release used only by a configured market gateway
    ///         during liquidation cleanup.
    /// @dev Deliberately skips syncAccount: an under-margined account may remain
    ///      unhealthy until its positions are reduced later in the same liquidation.
    function gatewayLiquidationReleaseExposure(
        uint256 marketIndex,
        address account,
        IOrderBookCore.Side side,
        uint96 lots
    ) external {
        IOrderBookCore core = _gatewayCore(marketIndex);
        core.moduleReleaseExposure(account, side, lots);
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
        IOrderBookCore core = _gatewayCore(marketIndex);
        filledLots = core.moduleTake(
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
        IOrderBookCore core = _gatewayCore(marketIndex);
        mintedShares = core.moduleAddLiquidity(
            account,
            side,
            tick,
            lots,
            reservedRiskCeiling
        );
        syncAccount(account);
    }

    function _core(uint256 marketIndex)
        internal
        view
        returns (IOrderBookCore core)
    {
        if (marketIndex >= markets.length) revert InvalidPortfolioAdmissionConfig();
        core = markets[marketIndex].core;
        if (core.portfolioController() != address(this)) {
            revert InvalidPortfolioAdmissionConfig();
        }
    }

    function _gatewayCore(uint256 marketIndex)
        internal
        view
        returns (IOrderBookCore core)
    {
        core = _core(marketIndex);
        if (msg.sender != markets[marketIndex].gateway) {
            revert UnauthorizedGateway();
        }
    }
}

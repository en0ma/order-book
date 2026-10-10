// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {ILiquidationGateway} from "./ILiquidationGateway.sol";
import {OrderBookMath} from "./OrderBookMath.sol";

interface IStrategyGatewayDiscovery {
    function executionStrategyModule() external view returns (address);
}

interface IStrategyOrderRegistry {
    function activeStrategyCount(address account) external view returns (uint32);
}

/// @title LiquidationPolicy
/// @notice Reusable liquidation health and bad-debt policy for CLOB integrations.
/// @dev Keeps read-side risk policy separate from liquidation execution/orchestration.
contract LiquidationPolicy {
    error InvalidLiquidationPolicyConfig();

    IOrderBookCore public immutable core;
    ILiquidationGateway public immutable gateway;
    uint16 public immutable maintenanceMarginBps;

    constructor(address core_, address gateway_, uint16 maintenanceBps_) {
        if (
            core_ == address(0) || gateway_ == address(0) || maintenanceBps_ == 0
                || maintenanceBps_ > 10_000
        ) revert InvalidLiquidationPolicyConfig();

        core = IOrderBookCore(core_);
        gateway = ILiquidationGateway(gateway_);
        maintenanceMarginBps = maintenanceBps_;
    }

    function hasOpenOrders(address account) public view returns (bool) {
        if (
            core.activeQuoteCount(account) != 0
                || gateway.activeAdvancedOrders(account) != 0
        ) return true;

        try IStrategyGatewayDiscovery(address(gateway)).executionStrategyModule()
            returns (address strategy)
        {
            return strategy != address(0)
                && IStrategyOrderRegistry(strategy).activeStrategyCount(account) != 0;
        } catch {
            // Unknown strategy-order state is not proof that the account is clear.
            // Fail closed rather than admitting liquidation or terminal debt.
            return true;
        }
    }

    function maintenanceRequirement(address account) external view returns (uint256) {
        (int80 position,,) = core.accountRisk(account);
        return maintenanceRequirementForPosition(position);
    }

    function maintenanceRequirementForPosition(int80 position)
        public
        view
        returns (uint256)
    {
        uint256 absPosition = uint256(OrderBookMath.absPosition(position));

        return core.notionalValue(uint96(absPosition), core.currentMarkTick())
            * uint256(maintenanceMarginBps) / 10_000;
    }

    function terminalBadDebt(address account) external view returns (uint256) {
        if (hasOpenOrders(account)) return 0;

        (int80 position,,) = core.accountRisk(account);
        if (position != 0) return 0;

        int256 equity = core.accountEquity(account);
        return equity < 0 ? uint256(-equity) : 0;
    }

    function isLiquidatable(address account) external view returns (bool) {
        if (hasOpenOrders(account)) return false;

        (int80 position,,) = core.accountRisk(account);
        if (position == 0) return false;

        return core.accountEquity(account)
            < int256(maintenanceRequirementForPosition(position));
    }
}

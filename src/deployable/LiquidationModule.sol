// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {OrderBookMath} from "./OrderBookMath.sol";

interface IAdvancedLiquidationGateway {
    function activeAdvancedOrders(address account) external view returns (uint32);

    function liquidationCleanupAdvanced(
        address account,
        uint64[] calldata conditionalIds,
        uint64[] calldata trailingIds
    ) external;

    function liquidationForceCancelQuote(
        address account,
        IOrderBookCore.Side side,
        uint16 tick
    ) external returns (uint96 removedLots);

    function liquidationTake(
        address account,
        IOrderBookCore.Side side,
        uint16 limitTick,
        uint96 lots
    ) external returns (uint96 filledLots);
}

/// @title LiquidationModule
/// @notice Maintenance-health policy and liquidation orchestration.
/// @dev Advanced-order storage cleanup is delegated back to AdvancedOrderModule.
contract LiquidationModule {
    error InvalidLiquidationConfig();
    error NotLiquidatable();
    error UnsettledOrders();

    IOrderBookCore public immutable core;
    IAdvancedLiquidationGateway public immutable gateway;
    uint16 public immutable maintenanceMarginBps;

    event Liquidated(
        address indexed liquidator,
        address indexed account,
        uint96 closedLots,
        int256 equityBefore
    );

    constructor(address core_, address gateway_, uint16 maintenanceBps_) {
        if (
            core_ == address(0) || gateway_ == address(0) || maintenanceBps_ == 0
                || maintenanceBps_ > 10_000
        ) revert InvalidLiquidationConfig();

        core = IOrderBookCore(core_);
        gateway = IAdvancedLiquidationGateway(gateway_);
        maintenanceMarginBps = maintenanceBps_;
    }

    function maintenanceRequirement(address account) public view returns (uint256) {
        (int80 position,,) = core.accountRisk(account);
        uint256 absPosition = uint256(OrderBookMath.absPosition(position));

        return absPosition * uint256(core.currentMarkTick())
            * uint256(maintenanceMarginBps) / 10_000;
    }

    function isLiquidatable(address account) external view returns (bool) {
        if (
            core.activeQuoteCount(account) != 0
                || gateway.activeAdvancedOrders(account) != 0
        ) return false;

        (int80 position,,) = core.accountRisk(account);
        if (position == 0) return false;

        return core.accountEquity(account) < int256(maintenanceRequirement(account));
    }

    function liquidate(
        address account,
        IOrderBookCore.Side[] calldata makerSides,
        uint16[] calldata makerTicks,
        uint64[] calldata conditionalIds,
        uint64[] calldata trailingIds
    ) external returns (uint96 closedLots) {
        if (makerSides.length != makerTicks.length) revert UnsettledOrders();

        gateway.liquidationCleanupAdvanced(account, conditionalIds, trailingIds);

        for (uint256 i; i < makerTicks.length; ++i) {
            gateway.liquidationForceCancelQuote(
                account, makerSides[i], makerTicks[i]
            );
        }

        if (
            core.activeQuoteCount(account) != 0
                || gateway.activeAdvancedOrders(account) != 0
        ) revert UnsettledOrders();

        int256 equityBefore = core.accountEquity(account);
        if (equityBefore >= int256(maintenanceRequirement(account))) {
            revert NotLiquidatable();
        }

        (int80 position,,) = core.accountRisk(account);

        if (position > 0) {
            closedLots = gateway.liquidationTake(
                account,
                IOrderBookCore.Side.Ask,
                0,
                uint96(uint80(position))
            );
        } else if (position < 0) {
            closedLots = gateway.liquidationTake(
                account,
                IOrderBookCore.Side.Bid,
                type(uint16).max,
                uint96(uint80(-position))
            );
        } else {
            revert NotLiquidatable();
        }

        emit Liquidated(msg.sender, account, closedLots, equityBefore);
    }
}

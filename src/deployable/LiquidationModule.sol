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

    function liquidationCoverBadDebt(address account, uint256 requested)
        external
        returns (uint256 covered);

    function liquidationPayReward(address liquidator, uint256 requested)
        external
        returns (uint256 paid);
}

/// @title LiquidationModule
/// @notice Maintenance-health policy and liquidation orchestration.
/// @dev Advanced-order storage cleanup is delegated back to AdvancedOrderModule.
contract LiquidationModule {
    error InvalidLiquidationConfig();
    error NotLiquidatable();
    error UnsettledOrders();
    error RewardAlreadyConfigured();
    error Unauthorized();

    IOrderBookCore public immutable core;
    IAdvancedLiquidationGateway public immutable gateway;
    uint16 public immutable maintenanceMarginBps;
    address internal immutable owner;
    uint16 public liquidatorRewardBps;
    bool public liquidatorRewardConfigured;

    event Liquidated(
        address indexed liquidator,
        address indexed account,
        uint96 closedLots,
        int256 equityBefore
    );

    event LiquidationStatus(
        address indexed account,
        int80 remainingPosition,
        int256 equityAfter,
        uint256 maintenanceRequirementAfter,
        uint256 insuranceCovered,
        uint256 terminalBadDebt
    );
    event LiquidatorRewardConfigured(uint16 rewardBps);
    event LiquidatorRewardPaid(address indexed liquidator, uint256 amount);

    constructor(address core_, address gateway_, uint16 maintenanceBps_) {
        if (
            core_ == address(0) || gateway_ == address(0) || maintenanceBps_ == 0
                || maintenanceBps_ > 10_000
        ) revert InvalidLiquidationConfig();

        core = IOrderBookCore(core_);
        gateway = IAdvancedLiquidationGateway(gateway_);
        maintenanceMarginBps = maintenanceBps_;
        owner = msg.sender;
    }

    function configureLiquidatorReward(uint16 rewardBps) external {
        if (msg.sender != owner) revert Unauthorized();
        if (liquidatorRewardConfigured) revert RewardAlreadyConfigured();
        if (rewardBps > 1_000) revert InvalidLiquidationConfig();

        liquidatorRewardConfigured = true;
        liquidatorRewardBps = rewardBps;
        emit LiquidatorRewardConfigured(rewardBps);
    }

    function maintenanceRequirement(address account) public view returns (uint256) {
        (int80 position,,) = core.accountRisk(account);
        uint256 absPosition = uint256(OrderBookMath.absPosition(position));

        return core.notionalValue(uint96(absPosition), core.currentMarkTick())
            * uint256(maintenanceMarginBps) / 10_000;
    }

    function terminalBadDebt(address account) public view returns (uint256) {
        if (
            core.activeQuoteCount(account) != 0
                || gateway.activeAdvancedOrders(account) != 0
        ) return 0;

        (int80 position,,) = core.accountRisk(account);
        if (position != 0) return 0;

        int256 equity = core.accountEquity(account);
        return equity < 0 ? uint256(-equity) : 0;
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

        (int80 remainingPosition,,) = core.accountRisk(account);
        int256 equityAfter = core.accountEquity(account);
        uint256 maintenanceAfter = maintenanceRequirement(account);
        uint256 badDebt =
            remainingPosition == 0 && equityAfter < 0 ? uint256(-equityAfter) : 0;

        uint256 insuranceCovered;
        if (badDebt != 0) {
            insuranceCovered = gateway.liquidationCoverBadDebt(account, badDebt);
            if (insuranceCovered != 0) {
                equityAfter = core.accountEquity(account);
                badDebt = equityAfter < 0 ? uint256(-equityAfter) : 0;
            }
        }

        emit LiquidationStatus(
            account,
            remainingPosition,
            equityAfter,
            maintenanceAfter,
            insuranceCovered,
            badDebt
        );

        uint16 rewardBps = liquidatorRewardBps;
        if (closedLots != 0 && rewardBps != 0) {
            uint256 requestedReward =
                core.notionalValue(closedLots, core.currentMarkTick())
                    * uint256(rewardBps) / 10_000;
            uint256 paid =
                gateway.liquidationPayReward(msg.sender, requestedReward);
            if (paid != 0) emit LiquidatorRewardPaid(msg.sender, paid);
        }
    }
}

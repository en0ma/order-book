// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {ILiquidationGateway} from "./ILiquidationGateway.sol";
import {LiquidationPolicy} from "./LiquidationPolicy.sol";

/// @title LiquidationModule
/// @notice Maintenance-health policy and liquidation orchestration.
/// @dev Advanced-order storage cleanup is delegated back to AdvancedOrderModule.
contract LiquidationModule {
    error InvalidLiquidationConfig();
    error NotLiquidatable();
    error UnsettledOrders();

    IOrderBookCore public immutable core;
    ILiquidationGateway public immutable gateway;
    LiquidationPolicy public immutable policy;
    uint16 public immutable maintenanceMarginBps;
    address public owner;
    uint16 public liquidatorRewardBps;
    bool internal _liquidatorRewardConfigured;

    event OwnershipTransferred(address indexed previousOwner, address indexed nextOwner);
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
        gateway = ILiquidationGateway(gateway_);
        policy = new LiquidationPolicy(core_, gateway_, maintenanceBps_);
        maintenanceMarginBps = maintenanceBps_;
        owner = msg.sender;
    }

    function transferOwnership(address nextOwner) external {
        if (msg.sender != owner || nextOwner == address(0)) {
            revert InvalidLiquidationConfig();
        }
        address previousOwner = owner;
        owner = nextOwner;
        emit OwnershipTransferred(previousOwner, nextOwner);
    }

    function configureLiquidatorReward(uint16 rewardBps) external {
        if (msg.sender != owner) revert InvalidLiquidationConfig();
        if (_liquidatorRewardConfigured) revert InvalidLiquidationConfig();
        if (rewardBps > 1_000) revert InvalidLiquidationConfig();

        _liquidatorRewardConfigured = true;
        liquidatorRewardBps = rewardBps;
        emit LiquidatorRewardConfigured(rewardBps);
    }

    function maintenanceRequirement(address account) external view returns (uint256) {
        return policy.maintenanceRequirement(account);
    }

    function terminalBadDebt(address account) external view returns (uint256) {
        return policy.terminalBadDebt(account);
    }

    function isLiquidatable(address account) external view returns (bool) {
        return policy.isLiquidatable(account);
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

        if (policy.hasOpenOrders(account)) revert UnsettledOrders();

        int256 equityBefore = core.accountEquity(account);
        (int80 position,,) = core.accountRisk(account);
        if (
            equityBefore
                >= int256(policy.maintenanceRequirementForPosition(position))
        ) {
            revert NotLiquidatable();
        }

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
        _finalizeLiquidation(account, closedLots, msg.sender);
    }

    function _finalizeLiquidation(
        address account,
        uint96 closedLots,
        address liquidator
    ) internal {
        (int80 remainingPosition,,) = core.accountRisk(account);
        int256 equityAfter = core.accountEquity(account);
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
            policy.maintenanceRequirementForPosition(remainingPosition),
            insuranceCovered,
            badDebt
        );

        uint16 rewardBps = liquidatorRewardBps;
        if (closedLots == 0 || rewardBps == 0) return;

        uint256 requestedReward =
            core.notionalValue(closedLots, core.currentMarkTick())
                * uint256(rewardBps) / 10_000;
        uint256 paid =
            gateway.liquidationPayReward(liquidator, requestedReward);
        if (paid != 0) emit LiquidatorRewardPaid(liquidator, paid);
    }
}

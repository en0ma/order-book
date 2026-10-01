// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";

/// @title ILiquidationGateway
/// @notice Integration boundary between liquidation orchestration and DEX-specific execution/custody hooks.
interface ILiquidationGateway {
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

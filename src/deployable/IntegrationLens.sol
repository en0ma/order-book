// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {OrderBookMath} from "./OrderBookMath.sol";

interface IAdvancedOrderIntegration {
    struct TrailingOrder {
        address owner;
        uint96 lots;
        uint64 observationId;
        uint16 trailTicks;
        uint16 limitTick;
        uint16 riskCeilingTick;
        IOrderBookCore.Side side;
        IOrderBookCore.FillPolicy policy;
        uint8 flags;
    }

    struct RestingLink {
        uint128 shares;
        uint96 remainingClaimLots;
        uint96 cumulativeFilledLots;
        uint32 generation;
        bool active;
    }

    function activeAdvancedOrders(address account) external view returns (uint32);
    function conditionalExpiry(uint64 orderId) external view returns (uint64);
    function trailingExpiry(uint64 orderId) external view returns (uint64);

    function conditionalOrders(uint64 orderId)
        external
        view
        returns (
            address owner,
            uint96 lots,
            uint64 sibling,
            uint16 triggerTick,
            uint16 limitTick,
            uint16 riskCeilingTick,
            IOrderBookCore.Side side,
            IOrderBookCore.FillPolicy policy,
            uint8 flags
        );

    function trailingOrderState(uint64 orderId)
        external
        view
        returns (TrailingOrder memory order);

    function restingOrderState(uint64 orderId)
        external
        view
        returns (RestingLink memory link);

    function otoState(uint64 orderId)
        external
        view
        returns (
            uint64 parentOrderId,
            uint64 firstChildOrderId,
            uint64 secondChildOrderId,
            uint96 childMaxLots
        );
}

/// @title IntegrationLens
/// @notice Bounded, read-only integration surface for DEX UIs, APIs, indexers and keepers.
/// @dev Enumeration remains off-chain. Callers supply the accounts, ticks and order IDs they need.
contract IntegrationLens {
    uint256 public constant MAX_BATCH = 64;
    uint256 public constant MAX_SCAN_TICKS = 256;

    struct TickKey {
        IOrderBookCore.Side side;
        uint16 tick;
    }

    struct PoolState {
        IOrderBookCore.Side side;
        uint16 tick;
        uint128 totalShares;
        uint96 remainingLots;
        uint32 generation;
    }

    struct QuoteState {
        IOrderBookCore.Side side;
        uint16 tick;
        uint128 shares;
        uint96 claimLots;
        uint96 currentRedeemableLots;
        uint96 pendingFillLots;
        uint32 generation;
        uint32 poolGeneration;
    }

    struct AccountState {
        int80 settledPosition;
        int80 minPosition;
        int80 maxPosition;
        int256 marketValue;
        int256 equity;
        uint32 activeQuoteCount;
        uint32 activeAdvancedCount;
        address portfolioController;
    }

    struct ConditionalState {
        address owner;
        uint96 lots;
        uint64 sibling;
        uint64 expiry;
        uint64 otoParent;
        uint64 otoChildOne;
        uint64 otoChildTwo;
        uint96 otoChildMaxLots;
        uint16 triggerTick;
        uint16 limitTick;
        uint16 riskCeilingTick;
        IOrderBookCore.Side side;
        IOrderBookCore.FillPolicy policy;
        uint8 flags;
        IAdvancedOrderIntegration.RestingLink resting;
    }

    struct TrailingState {
        IAdvancedOrderIntegration.TrailingOrder order;
        uint64 expiry;
    }

    error InvalidConfig();
    error BatchTooLarge();
    error InvalidRange();

    IOrderBookCore public immutable core;
    IAdvancedOrderIntegration public immutable advanced;

    constructor(address core_, address advanced_) {
        if (core_ == address(0) || advanced_ == address(0)) revert InvalidConfig();
        core = IOrderBookCore(core_);
        advanced = IAdvancedOrderIntegration(advanced_);
    }

    function accountState(address account)
        external
        view
        returns (AccountState memory state)
    {
        (
            state.settledPosition,
            state.minPosition,
            state.maxPosition
        ) = core.accountRisk(account);
        state.marketValue = core.accountMarketValue(account);
        state.equity = core.accountEquity(account);
        state.activeQuoteCount = core.activeQuoteCount(account);
        state.activeAdvancedCount = advanced.activeAdvancedOrders(account);
        state.portfolioController = core.portfolioController();
    }

    function poolStates(TickKey[] calldata keys)
        external
        view
        returns (PoolState[] memory states)
    {
        _checkBatch(keys.length);
        states = new PoolState[](keys.length);

        for (uint256 i; i < keys.length; ++i) {
            TickKey calldata key = keys[i];
            (
                uint128 totalShares,
                uint96 remainingLots,
                uint32 generation
            ) = core.pools(key.side, key.tick);
            states[i] = PoolState(
                key.side,
                key.tick,
                totalShares,
                remainingLots,
                generation
            );
        }
    }

    function quoteStates(address account, TickKey[] calldata keys)
        external
        view
        returns (QuoteState[] memory states)
    {
        _checkBatch(keys.length);
        states = new QuoteState[](keys.length);

        for (uint256 i; i < keys.length; ++i) {
            TickKey calldata key = keys[i];
            (
                uint128 shares,
                uint96 claimLots,
                uint32 generation
            ) = core.quotes(account, key.side, key.tick);
            (
                uint128 totalShares,
                uint96 remainingLots,
                uint32 poolGeneration
            ) = core.pools(key.side, key.tick);

            uint96 currentRedeemableLots;
            if (shares != 0 && generation == poolGeneration) {
                currentRedeemableLots = OrderBookMath.redeemableLotsCeil(
                    shares,
                    remainingLots,
                    totalShares
                );
                if (currentRedeemableLots > claimLots) {
                    currentRedeemableLots = claimLots;
                }
            }

            states[i] = QuoteState({
                side: key.side,
                tick: key.tick,
                shares: shares,
                claimLots: claimLots,
                currentRedeemableLots: currentRedeemableLots,
                pendingFillLots: core.previewMakerFill(account, key.side, key.tick),
                generation: generation,
                poolGeneration: poolGeneration
            });
        }
    }

    function conditionalStates(uint64[] calldata orderIds)
        external
        view
        returns (ConditionalState[] memory states)
    {
        _checkBatch(orderIds.length);
        states = new ConditionalState[](orderIds.length);

        for (uint256 i; i < orderIds.length; ++i) {
            uint64 orderId = orderIds[i];
            ConditionalState memory state;
            (
                state.owner,
                state.lots,
                state.sibling,
                state.triggerTick,
                state.limitTick,
                state.riskCeilingTick,
                state.side,
                state.policy,
                state.flags
            ) = advanced.conditionalOrders(orderId);
            state.expiry = advanced.conditionalExpiry(orderId);
            (
                state.otoParent,
                state.otoChildOne,
                state.otoChildTwo,
                state.otoChildMaxLots
            ) = advanced.otoState(orderId);
            state.resting = advanced.restingOrderState(orderId);
            states[i] = state;
        }
    }

    function trailingStates(uint64[] calldata orderIds)
        external
        view
        returns (TrailingState[] memory states)
    {
        _checkBatch(orderIds.length);
        states = new TrailingState[](orderIds.length);

        for (uint256 i; i < orderIds.length; ++i) {
            uint64 orderId = orderIds[i];
            states[i] = TrailingState({
                order: advanced.trailingOrderState(orderId),
                expiry: advanced.trailingExpiry(orderId)
            });
        }
    }

    /// @notice Returns aggregate non-empty levels in the supplied inclusive range.
    /// @dev The caller chooses the bounded scan window. For bids, levels are returned
    ///      high-to-low; for asks, low-to-high.
    function depthInRange(
        IOrderBookCore.Side side,
        uint16 lowTick,
        uint16 highTick,
        uint16 maxLevels
    ) external view returns (PoolState[] memory levels) {
        uint256 span = uint256(highTick) - uint256(lowTick) + 1;
        if (
            lowTick > highTick || maxLevels == 0 || maxLevels > MAX_BATCH
                || span > MAX_SCAN_TICKS
        ) {
            revert InvalidRange();
        }

        levels = new PoolState[](maxLevels);
        uint256 count;

        if (side == IOrderBookCore.Side.Ask) {
            for (uint256 raw = lowTick; raw <= highTick && count < maxLevels; ++raw) {
                uint16 tick = uint16(raw);
                (uint128 shares, uint96 lots, uint32 generation) =
                    core.pools(side, tick);
                if (lots != 0) {
                    levels[count++] =
                        PoolState(side, tick, shares, lots, generation);
                }
            }
        } else {
            uint256 raw = highTick;
            while (raw >= lowTick && count < maxLevels) {
                uint16 tick = uint16(raw);
                (uint128 shares, uint96 lots, uint32 generation) =
                    core.pools(side, tick);
                if (lots != 0) {
                    levels[count++] =
                        PoolState(side, tick, shares, lots, generation);
                }
                if (raw == lowTick) break;
                unchecked {
                    --raw;
                }
            }
        }

        assembly ("memory-safe") {
            mstore(levels, count)
        }
    }

    function _checkBatch(uint256 length) internal pure {
        if (length > MAX_BATCH) revert BatchTooLarge();
    }
}

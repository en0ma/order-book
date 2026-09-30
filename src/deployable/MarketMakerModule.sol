// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOrderBookCore} from "./IOrderBookCore.sol";
import {OrderBookMath} from "./OrderBookMath.sol";

interface IAdvancedQuoteGateway {
    function marketMakerReserveExposure(
        address maker,
        IOrderBookCore.Side side,
        uint96 lots
    ) external returns (uint16 riskCeilingTick);

    function marketMakerAddLiquidity(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 lots,
        uint16 riskCeilingTick
    ) external returns (uint128 shares);

    function marketMakerRemoveLockedShares(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick,
        uint32 generation,
        uint128 shares
    ) external returns (uint96 removedLots);

    function marketMakerUnlockShares(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick,
        uint32 generation,
        uint128 shares
    ) external;
}

/// @title MarketMakerModule
/// @notice Owns managed quote metadata and atomic quote refresh policy.
/// @dev Canonical liquidity, risk and matching remain in OrderBookCore.
contract MarketMakerModule {
    struct ManagedQuote {
        uint128 shares;
        uint32 generation;
    }

    struct QuoteUpdate {
        IOrderBookCore.Side side;
        uint16 tick;
        uint96 lots;
    }

    error ZeroAmount();

    IOrderBookCore public immutable core;
    IAdvancedQuoteGateway public immutable gateway;

    mapping(address => mapping(IOrderBookCore.Side => mapping(uint16 => ManagedQuote)))
        internal managedQuotes;

    constructor(address core_, address gateway_) {
        if (core_ == address(0) || gateway_ == address(0)) revert ZeroAmount();
        core = IOrderBookCore(core_);
        gateway = IAdvancedQuoteGateway(gateway_);
    }

    /// @notice Atomically replace/cancel module-managed maker quotes.
    /// @dev lots == 0 cancels the managed slice at that maker/side/tick.
    function batchReplaceQuotes(QuoteUpdate[] calldata updates) external {
        uint256 length = updates.length;
        if (length == 0) revert ZeroAmount();

        uint96[] memory additions = new uint96[](length);
        uint96 bidAddLots;
        uint96 askAddLots;

        // Phase 1: preserve same-generation slices when possible. Exact decreases
        // still clear/rebuild because share redemption rounds down in integer lots.
        for (uint256 i; i < length; ) {
            QuoteUpdate calldata update = updates[i];
            uint96 addLots =
                _prepareManagedTarget(msg.sender, update.side, update.tick, update.lots);
            additions[i] = addLots;

            if (update.side == IOrderBookCore.Side.Bid) {
                bidAddLots += addLots;
            } else {
                askAddLots += addLots;
            }

            unchecked {
                ++i;
            }
        }

        // Phase 2: reserve only the incremental exposure, once per side.
        uint16 bidCeiling;
        uint16 askCeiling;

        if (bidAddLots != 0) {
            bidCeiling = gateway.marketMakerReserveExposure(
                msg.sender, IOrderBookCore.Side.Bid, bidAddLots
            );
        }
        if (askAddLots != 0) {
            askCeiling = gateway.marketMakerReserveExposure(
                msg.sender, IOrderBookCore.Side.Ask, askAddLots
            );
        }

        // Phase 3: add only the missing quantity.
        for (uint256 i; i < length; ) {
            uint96 addLots = additions[i];
            if (addLots != 0) {
                QuoteUpdate calldata update = updates[i];
                uint16 ceiling =
                    update.side == IOrderBookCore.Side.Bid ? bidCeiling : askCeiling;

                uint128 shares = gateway.marketMakerAddLiquidity(
                    msg.sender,
                    update.side,
                    update.tick,
                    addLots,
                    ceiling
                );

                (,, uint32 generation) = core.pools(update.side, update.tick);
                ManagedQuote storage managed =
                    managedQuotes[msg.sender][update.side][update.tick];

                if (managed.shares == 0 || managed.generation != generation) {
                    managed.generation = generation;
                    managed.shares = shares;
                } else {
                    managed.shares += shares;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function _prepareManagedTarget(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick,
        uint96 targetLots
    ) internal returns (uint96 addLots) {
        ManagedQuote memory managed = managedQuotes[maker][side][tick];
        if (managed.shares == 0) return targetLots;

        (uint128 totalShares, uint96 remainingLots, uint32 currentGeneration) =
            core.pools(side, tick);

        if (currentGeneration != managed.generation) {
            gateway.marketMakerUnlockShares(
                maker,
                side,
                tick,
                managed.generation,
                managed.shares
            );
            delete managedQuotes[maker][side][tick];
            return targetLots;
        }

        uint96 currentLots =
            OrderBookMath.redeemableLots(managed.shares, remainingLots, totalShares);

        if (targetLots >= currentLots) {
            return targetLots - currentLots;
        }

        // Exact downsize: remove the slice, then phase 3 can rebuild targetLots.
        gateway.marketMakerRemoveLockedShares(
            maker,
            side,
            tick,
            managed.generation,
            managed.shares
        );
        delete managedQuotes[maker][side][tick];
        return targetLots;
    }

    function _clearManagedQuote(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick
    ) internal {
        ManagedQuote memory managed = managedQuotes[maker][side][tick];
        if (managed.shares == 0) return;

        (,, uint32 currentGeneration) = core.pools(side, tick);

        if (currentGeneration == managed.generation) {
            gateway.marketMakerRemoveLockedShares(
                maker,
                side,
                tick,
                managed.generation,
                managed.shares
            );
        } else {
            gateway.marketMakerUnlockShares(
                maker,
                side,
                tick,
                managed.generation,
                managed.shares
            );
        }

        delete managedQuotes[maker][side][tick];
    }
}

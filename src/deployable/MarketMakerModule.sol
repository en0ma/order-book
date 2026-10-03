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
    error InvalidPackedQuotes();
    error QuotesNotStrictlySorted();
    error Unauthorized();

    IOrderBookCore public immutable core;
    IAdvancedQuoteGateway public immutable gateway;

    mapping(address => mapping(IOrderBookCore.Side => mapping(uint16 => ManagedQuote)))
        internal managedQuotes;

    constructor(address core_, address gateway_) {
        if (core_ == address(0) || gateway_ == address(0)) revert ZeroAmount();
        core = IOrderBookCore(core_);
        gateway = IAdvancedQuoteGateway(gateway_);
    }

    function managedQuote(address maker, IOrderBookCore.Side side, uint16 tick)
        external
        view
        returns (uint128 shares, uint32 generation)
    {
        ManagedQuote memory managed = managedQuotes[maker][side][tick];
        return (managed.shares, managed.generation);
    }

    function liquidationForgetManagedQuote(
        address maker,
        IOrderBookCore.Side side,
        uint16 tick
    ) external {
        if (msg.sender != address(gateway)) revert Unauthorized();
        delete managedQuotes[maker][side][tick];
    }

    /// @notice Atomically replace/cancel module-managed maker quotes.
    /// @dev lots == 0 cancels the managed slice at that maker/side/tick.
    function batchReplaceQuotes(QuoteUpdate[] calldata updates) external {
        uint256 length = updates.length;
        if (length == 0) revert ZeroAmount();

        uint128[] memory words = new uint128[](length);
        for (uint256 i; i < length; ) {
            QuoteUpdate calldata update = updates[i];
            words[i] = _encode(update.side, update.tick, update.lots);
            unchecked {
                ++i;
            }
        }

        _batchReplaceWords(msg.sender, words);
    }

    /// @notice Packed quote refresh for latency-sensitive market makers.
    /// @dev Each 16-byte record is: lots[0..95], tick[96..111],
    ///      side[112] (0=Bid, 1=Ask), reserved[113..127]=0.
    function batchReplaceQuotesPacked(bytes calldata packed) external {
        uint256 byteLength = packed.length;
        if (byteLength == 0 || byteLength % 16 != 0) revert InvalidPackedQuotes();

        uint256 length = byteLength / 16;
        uint128[] memory words = new uint128[](length);

        for (uint256 i; i < length; ) {
            uint128 word;
            assembly ("memory-safe") {
                word := shr(128, calldataload(add(packed.offset, mul(i, 16))))
            }
            if (word >> 113 != 0) revert InvalidPackedQuotes();
            words[i] = word;

            unchecked {
                ++i;
            }
        }

        _batchReplaceWords(msg.sender, words);
    }

    function _batchReplaceWords(address maker, uint128[] memory words) internal {
        uint256 length = words.length;
        uint96[] memory additions = new uint96[](length);
        uint96 bidAddLots;
        uint96 askAddLots;
        uint32 previousKey;

        // Phase 1: require deterministic side/tick ordering and preserve
        // same-generation slices when possible.
        for (uint256 i; i < length; ) {
            uint32 key = uint32(words[i] >> 96);
            if (i != 0 && key <= previousKey) revert QuotesNotStrictlySorted();
            previousKey = key;

            unchecked {
                ++i;
            }
        }

        // Phase 1b: preserve same-generation slices when possible. Exact decreases
        // still clear/rebuild because share redemption rounds down in integer lots.
        for (uint256 i; i < length; ) {
            uint128 word = words[i];
            IOrderBookCore.Side side = _side(word);
            uint96 addLots =
                _prepareManagedTarget(maker, side, _tick(word), _lots(word));
            additions[i] = addLots;

            if (side == IOrderBookCore.Side.Bid) {
                bidAddLots += addLots;
            } else {
                askAddLots += addLots;
            }

            unchecked {
                ++i;
            }
        }

        // Phase 2: reserve only incremental exposure, once per side.
        uint16 bidCeiling;
        uint16 askCeiling;

        if (bidAddLots != 0) {
            bidCeiling =
                gateway.marketMakerReserveExposure(maker, IOrderBookCore.Side.Bid, bidAddLots);
        }
        if (askAddLots != 0) {
            askCeiling =
                gateway.marketMakerReserveExposure(maker, IOrderBookCore.Side.Ask, askAddLots);
        }

        // Phase 3: add only missing quantity.
        for (uint256 i; i < length; ) {
            uint96 addLots = additions[i];
            if (addLots != 0) {
                _addManagedLots(
                    maker,
                    words[i],
                    addLots,
                    bidCeiling,
                    askCeiling
                );
            }

            unchecked {
                ++i;
            }
        }
    }

    function _addManagedLots(
        address maker,
        uint128 word,
        uint96 addLots,
        uint16 bidCeiling,
        uint16 askCeiling
    ) internal {
        IOrderBookCore.Side side = _side(word);
        uint16 tick = _tick(word);
        uint16 ceiling =
            side == IOrderBookCore.Side.Bid ? bidCeiling : askCeiling;

        uint128 shares =
            gateway.marketMakerAddLiquidity(maker, side, tick, addLots, ceiling);

        (,, uint32 generation) = core.pools(side, tick);
        ManagedQuote storage managed = managedQuotes[maker][side][tick];

        if (managed.shares == 0 || managed.generation != generation) {
            managed.generation = generation;
            managed.shares = shares;
        } else {
            managed.shares += shares;
        }
    }

    function _encode(IOrderBookCore.Side side, uint16 tick, uint96 lots)
        internal
        pure
        returns (uint128 word)
    {
        word = uint128(lots) | (uint128(tick) << 96) | (uint128(uint8(side)) << 112);
    }

    function _side(uint128 word) internal pure returns (IOrderBookCore.Side) {
        return IOrderBookCore.Side(uint8(word >> 112));
    }

    function _tick(uint128 word) internal pure returns (uint16) {
        return uint16(word >> 96);
    }

    function _lots(uint128 word) internal pure returns (uint96) {
        return uint96(word);
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
            OrderBookMath.redeemableLotsCeil(managed.shares, remainingLots, totalShares);

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

}

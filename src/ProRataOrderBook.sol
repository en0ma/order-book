// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ProRataOrderBook
/// @notice Experimental fully-on-chain order book kernel.
/// @dev Best-price priority across ticks, pro-rata allocation within a tick.
///      This prototype intentionally excludes custody, fees, liquidation and oracle wiring.
contract ProRataOrderBook {
    uint256 public constant INDEX_SCALE = 1 << 96;
    uint256 public constant INITIAL_SHARE_SCALE = 1_000_000;

    enum Side {
        Bid,
        Ask
    }

    enum FillPolicy {
        IOC,
        FOK
    }

    struct TickPool {
        uint128 totalShares;
        uint96 remainingLots;
        uint32 generation;
        uint128 fillIndexX96;
        uint128 fillRemainder;
    }

    struct MakerQuote {
        uint128 shares;
        uint128 fillCheckpointX96;
        uint128 makerRemainderX96;
        uint32 generation;
    }

    struct ClosedGeneration {
        uint128 finalFillIndexX96;
        uint128 outstandingShares;
    }

    struct AccountRisk {
        int128 settledPosition;
        int128 minPosition;
        int128 maxPosition;
    }

    error ZeroAmount();
    error CrossesBook();
    error InsufficientLiquidity();
    error InvalidShareAmount();
    error StaleQuote();
    error Overflow();

    mapping(Side => mapping(uint16 => TickPool)) public pools;
    mapping(address => mapping(Side => mapping(uint16 => MakerQuote))) public quotes;
    mapping(address => AccountRisk) public accountRisk;
    mapping(Side => mapping(uint16 => mapping(uint32 => ClosedGeneration))) public closedGenerations;

    mapping(Side => mapping(uint8 => uint256)) internal _tickWords;
    mapping(Side => uint256) internal _occupiedWords;

    uint256 public totalAddedLots;
    uint256 public totalRemovedLots;
    uint256 public totalExecutedLots;
    uint256 public protocolFillDustX96;

    event LiquidityAdded(
        address indexed maker,
        Side indexed side,
        uint16 indexed tick,
        uint96 lots,
        uint128 shares,
        uint32 generation
    );
    event LiquidityRemoved(
        address indexed maker,
        Side indexed side,
        uint16 indexed tick,
        uint96 lots,
        uint128 shares,
        uint32 generation
    );
    event MakerSettled(
        address indexed maker,
        Side indexed side,
        uint16 indexed tick,
        uint96 filledLots,
        uint32 generation
    );
    event Trade(
        address indexed taker,
        Side indexed takerSide,
        uint16 indexed tick,
        uint96 lots
    );

    function addLiquidity(Side side, uint16 tick, uint96 lots)
        external
        returns (uint128 mintedShares)
    {
        if (lots == 0) revert ZeroAmount();
        _assertPostOnly(side, tick);
        _settle(msg.sender, side, tick);

        TickPool storage p = pools[side][tick];
        MakerQuote storage q = quotes[msg.sender][side][tick];

        bool wasEmpty = p.remainingLots == 0;
        if (p.totalShares == 0) {
            uint256 raw = uint256(lots) * INITIAL_SHARE_SCALE;
            if (raw > type(uint128).max) revert Overflow();
            mintedShares = uint128(raw);
        } else {
            uint256 raw = uint256(lots) * uint256(p.totalShares) / uint256(p.remainingLots);
            if (raw == 0 || raw > type(uint128).max) revert InvalidShareAmount();
            mintedShares = uint128(raw);
        }

        uint256 nextShares = uint256(p.totalShares) + mintedShares;
        uint256 nextLots = uint256(p.remainingLots) + lots;
        if (nextShares > type(uint128).max || nextLots > type(uint96).max) revert Overflow();

        p.totalShares = uint128(nextShares);
        p.remainingLots = uint96(nextLots);

        if (q.shares == 0) {
            q.generation = p.generation;
            q.fillCheckpointX96 = p.fillIndexX96;
        } else if (q.generation != p.generation) {
            revert StaleQuote();
        }

        q.shares += mintedShares;
        q.fillCheckpointX96 = p.fillIndexX96;

        _expandRisk(msg.sender, side, lots);
        totalAddedLots += lots;

        if (wasEmpty) _setOccupied(side, tick, true);

        emit LiquidityAdded(msg.sender, side, tick, lots, mintedShares, p.generation);
    }

    function removeShares(Side side, uint16 tick, uint128 sharesToBurn)
        external
        returns (uint96 removedLots)
    {
        if (sharesToBurn == 0) revert ZeroAmount();
        _settle(msg.sender, side, tick);

        TickPool storage p = pools[side][tick];
        MakerQuote storage q = quotes[msg.sender][side][tick];
        if (q.shares == 0 || q.generation != p.generation) revert StaleQuote();
        if (sharesToBurn > q.shares) revert InvalidShareAmount();

        uint256 redeemed =
            uint256(sharesToBurn) * uint256(p.remainingLots) / uint256(p.totalShares);
        if (redeemed == 0 || redeemed > type(uint96).max) revert InvalidShareAmount();
        removedLots = uint96(redeemed);

        p.totalShares -= sharesToBurn;
        p.remainingLots -= removedLots;
        q.shares -= sharesToBurn;

        _shrinkRisk(msg.sender, side, removedLots);
        totalRemovedLots += removedLots;

        if (q.shares == 0) {
            protocolFillDustX96 += q.makerRemainderX96;
            delete quotes[msg.sender][side][tick];
        } else {
            q.fillCheckpointX96 = p.fillIndexX96;
        }

        if (p.totalShares == 0) {
            if (p.remainingLots != 0) revert InvalidShareAmount();
            _setOccupied(side, tick, false);
            unchecked {
                ++p.generation;
            }
            p.fillIndexX96 = 0;
            p.fillRemainder = 0;
        }

        emit LiquidityRemoved(
            msg.sender, side, tick, removedLots, sharesToBurn, p.generation
        );
    }

    function settle(Side side, uint16 tick) external returns (uint96 filledLots) {
        filledLots = _settle(msg.sender, side, tick);
    }

    function take(Side takerSide, uint16 limitTick, uint96 lots, FillPolicy policy)
        external
        returns (uint96 filledLots)
    {
        if (lots == 0) revert ZeroAmount();

        Side makerSide = takerSide == Side.Bid ? Side.Ask : Side.Bid;

        if (policy == FillPolicy.FOK && _availableThrough(makerSide, limitTick, lots) < lots) {
            revert InsufficientLiquidity();
        }

        uint96 remaining = lots;
        while (remaining != 0) {
            (bool ok, uint16 tick) = _bestTick(makerSide);
            if (!ok) break;
            if (!_withinLimit(makerSide, tick, limitTick)) break;

            TickPool storage p = pools[makerSide][tick];
            uint96 fill = remaining < p.remainingLots ? remaining : p.remainingLots;

            _consume(makerSide, tick, p, fill);

            unchecked {
                remaining -= fill;
                filledLots += fill;
            }
            totalExecutedLots += fill;
            emit Trade(msg.sender, takerSide, tick, fill);
        }

        if (policy == FillPolicy.FOK && filledLots != lots) revert InsufficientLiquidity();
    }

    function quoteState(address maker, Side side, uint16 tick)
        external
        view
        returns (
            uint128 shares,
            uint32 generation,
            uint96 currentClaimLots,
            uint96 pendingFillLots
        )
    {
        MakerQuote memory q = quotes[maker][side][tick];
        if (q.shares == 0) return (0, 0, 0, 0);

        TickPool memory p = pools[side][tick];
        uint128 finalIndex;
        if (q.generation == p.generation) {
            finalIndex = p.fillIndexX96;
            currentClaimLots = uint96(
                uint256(q.shares) * uint256(p.remainingLots) / uint256(p.totalShares)
            );
        } else {
            ClosedGeneration memory c = closedGenerations[side][tick][q.generation];
            finalIndex = c.finalFillIndexX96;
        }

        uint256 n = uint256(q.shares) * uint256(finalIndex - q.fillCheckpointX96)
            + uint256(q.makerRemainderX96);
        uint256 f = n / INDEX_SCALE;
        if (f > type(uint96).max) revert Overflow();

        shares = q.shares;
        generation = q.generation;
        pendingFillLots = uint96(f);
    }

    function bestBid() external view returns (bool ok, uint16 tick) {
        return _bestTick(Side.Bid);
    }

    function bestAsk() external view returns (bool ok, uint16 tick) {
        return _bestTick(Side.Ask);
    }

    function occupiedWord(Side side, uint8 wordIndex) external view returns (uint256) {
        return _tickWords[side][wordIndex];
    }

    function occupiedWordBitmap(Side side) external view returns (uint256) {
        return _occupiedWords[side];
    }

    function _consume(Side side, uint16 tick, TickPool storage p, uint96 fill) internal {
        uint256 n = uint256(fill) * INDEX_SCALE + uint256(p.fillRemainder);
        uint256 dI = n / uint256(p.totalShares);
        uint256 rem = n % uint256(p.totalShares);

        uint256 nextIndex = uint256(p.fillIndexX96) + dI;
        if (nextIndex > type(uint128).max || rem > type(uint128).max) revert Overflow();

        p.fillIndexX96 = uint128(nextIndex);
        p.fillRemainder = uint128(rem);
        p.remainingLots -= fill;

        if (p.remainingLots == 0) {
            uint32 oldGeneration = p.generation;
            closedGenerations[side][tick][oldGeneration] = ClosedGeneration({
                finalFillIndexX96: p.fillIndexX96,
                outstandingShares: p.totalShares
            });

            p.totalShares = 0;
            p.fillIndexX96 = 0;
            p.fillRemainder = 0;
            unchecked {
                ++p.generation;
            }
            _setOccupied(side, tick, false);
        }
    }

    function _settle(address maker, Side side, uint16 tick)
        internal
        returns (uint96 filledLots)
    {
        MakerQuote storage q = quotes[maker][side][tick];
        if (q.shares == 0) return 0;

        TickPool storage p = pools[side][tick];

        uint128 finalIndex;
        bool closedGeneration = q.generation != p.generation;
        if (closedGeneration) {
            ClosedGeneration storage c = closedGenerations[side][tick][q.generation];
            finalIndex = c.finalFillIndexX96;
            if (c.outstandingShares < q.shares) revert StaleQuote();
        } else {
            finalIndex = p.fillIndexX96;
        }

        uint256 n = uint256(q.shares) * uint256(finalIndex - q.fillCheckpointX96)
            + uint256(q.makerRemainderX96);
        uint256 f = n / INDEX_SCALE;
        uint256 makerRem = n % INDEX_SCALE;
        if (f > type(uint96).max || makerRem > type(uint128).max) revert Overflow();

        filledLots = uint96(f);
        if (filledLots != 0) {
            AccountRisk storage a = accountRisk[maker];
            int128 signedFill = int128(uint128(filledLots));
            if (side == Side.Bid) {
                a.settledPosition += signedFill;
            } else {
                a.settledPosition -= signedFill;
            }
        }

        if (closedGeneration) {
            ClosedGeneration storage c = closedGenerations[side][tick][q.generation];
            c.outstandingShares -= q.shares;
            protocolFillDustX96 += makerRem;
            uint32 oldGeneration = q.generation;
            if (c.outstandingShares == 0) {
                delete closedGenerations[side][tick][oldGeneration];
            }
            delete quotes[maker][side][tick];
            emit MakerSettled(maker, side, tick, filledLots, oldGeneration);
        } else {
            q.fillCheckpointX96 = finalIndex;
            q.makerRemainderX96 = uint128(makerRem);
            emit MakerSettled(maker, side, tick, filledLots, q.generation);
        }
    }

    function _expandRisk(address maker, Side side, uint96 lots) internal {
        AccountRisk storage a = accountRisk[maker];
        int128 amount = int128(uint128(lots));
        if (side == Side.Bid) {
            a.maxPosition += amount;
        } else {
            a.minPosition -= amount;
        }
    }

    function _shrinkRisk(address maker, Side side, uint96 lots) internal {
        AccountRisk storage a = accountRisk[maker];
        int128 amount = int128(uint128(lots));
        if (side == Side.Bid) {
            a.maxPosition -= amount;
        } else {
            a.minPosition += amount;
        }
    }

    function _assertPostOnly(Side side, uint16 tick) internal view {
        if (side == Side.Bid) {
            (bool ok, uint16 ask) = _bestTick(Side.Ask);
            if (ok && tick >= ask) revert CrossesBook();
        } else {
            (bool ok, uint16 bid) = _bestTick(Side.Bid);
            if (ok && tick <= bid) revert CrossesBook();
        }
    }

    function _withinLimit(Side makerSide, uint16 makerTick, uint16 limitTick)
        internal
        pure
        returns (bool)
    {
        return makerSide == Side.Ask ? makerTick <= limitTick : makerTick >= limitTick;
    }

    function _availableThrough(Side makerSide, uint16 limitTick, uint96 stopAt)
        internal
        view
        returns (uint256 available)
    {
        (bool ok, uint16 tick) = _bestTick(makerSide);
        while (ok && _withinLimit(makerSide, tick, limitTick)) {
            available += pools[makerSide][tick].remainingLots;
            if (available >= stopAt) return available;
            (ok, tick) = _nextTick(makerSide, tick);
        }
    }

    function _setOccupied(Side side, uint16 tick, bool occupied) internal {
        uint8 wordIndex = uint8(tick >> 8);
        uint8 bitIndex = uint8(tick);
        uint256 bit = uint256(1) << bitIndex;
        uint256 word = _tickWords[side][wordIndex];

        if (occupied) {
            uint256 next = word | bit;
            _tickWords[side][wordIndex] = next;
            if (word == 0) _occupiedWords[side] |= uint256(1) << wordIndex;
        } else {
            uint256 next = word & ~bit;
            _tickWords[side][wordIndex] = next;
            if (next == 0) _occupiedWords[side] &= ~(uint256(1) << wordIndex);
        }
    }

    function _bestTick(Side side) internal view returns (bool ok, uint16 tick) {
        uint256 words = _occupiedWords[side];
        if (words == 0) return (false, 0);

        uint8 wordIndex;
        uint8 bitIndex;
        if (side == Side.Ask) {
            wordIndex = _lsb(words);
            bitIndex = _lsb(_tickWords[side][wordIndex]);
        } else {
            wordIndex = _msb(words);
            bitIndex = _msb(_tickWords[side][wordIndex]);
        }

        tick = (uint16(wordIndex) << 8) | uint16(bitIndex);
        ok = true;
    }

    function _nextTick(Side side, uint16 current) internal view returns (bool ok, uint16 tick) {
        uint8 wi = uint8(current >> 8);
        uint8 bi = uint8(current);

        if (side == Side.Ask) {
            if (bi != type(uint8).max) {
                uint256 sameWord =
                    _tickWords[side][wi] & (type(uint256).max << (uint256(bi) + 1));
                if (sameWord != 0) {
                    return (true, (uint16(wi) << 8) | uint16(_lsb(sameWord)));
                }
            }
            if (wi == type(uint8).max) return (false, 0);
            uint256 higherWords =
                _occupiedWords[side] & (type(uint256).max << (uint256(wi) + 1));
            if (higherWords == 0) return (false, 0);
            uint8 nwi = _lsb(higherWords);
            return (true, (uint16(nwi) << 8) | uint16(_lsb(_tickWords[side][nwi])));
        }

        if (bi != 0) {
            uint256 sameWord = _tickWords[side][wi] & ((uint256(1) << bi) - 1);
            if (sameWord != 0) {
                return (true, (uint16(wi) << 8) | uint16(_msb(sameWord)));
            }
        }
        if (wi == 0) return (false, 0);
        uint256 lowerWords = _occupiedWords[side] & ((uint256(1) << wi) - 1);
        if (lowerWords == 0) return (false, 0);
        uint8 nwi = _msb(lowerWords);
        return (true, (uint16(nwi) << 8) | uint16(_msb(_tickWords[side][nwi])));
    }

    function _lsb(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert InsufficientLiquidity();
        if (x & type(uint128).max == 0) {
            x >>= 128;
            r += 128;
        }
        if (x & type(uint64).max == 0) {
            x >>= 64;
            r += 64;
        }
        if (x & type(uint32).max == 0) {
            x >>= 32;
            r += 32;
        }
        if (x & type(uint16).max == 0) {
            x >>= 16;
            r += 16;
        }
        if (x & type(uint8).max == 0) {
            x >>= 8;
            r += 8;
        }
        if (x & 0x0f == 0) {
            x >>= 4;
            r += 4;
        }
        if (x & 0x03 == 0) {
            x >>= 2;
            r += 2;
        }
        if (x & 0x01 == 0) r += 1;
    }

    function _msb(uint256 x) internal pure returns (uint8 r) {
        if (x == 0) revert InsufficientLiquidity();
        if (x >> 128 != 0) {
            x >>= 128;
            r += 128;
        }
        if (x >> 64 != 0) {
            x >>= 64;
            r += 64;
        }
        if (x >> 32 != 0) {
            x >>= 32;
            r += 32;
        }
        if (x >> 16 != 0) {
            x >>= 16;
            r += 16;
        }
        if (x >> 8 != 0) {
            x >>= 8;
            r += 8;
        }
        if (x >> 4 != 0) {
            x >>= 4;
            r += 4;
        }
        if (x >> 2 != 0) {
            x >>= 2;
            r += 2;
        }
        if (x >> 1 != 0) r += 1;
    }
}

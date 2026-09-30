# Architecture

This repository is an experimental fully-on-chain order-book kernel optimized around one constraint:

Taker execution should scale with the number of price levels crossed, not the number of makers filled.

## Matching rule

The prototype uses best-price priority across ticks and pro-rata allocation among all makers at exactly the same tick.

It deliberately does not implement per-order FIFO inside a tick. FIFO would require per-maker queue traversal or another time-bucket structure and would put maker-count-dependent work back onto the hot matching path.

## Tick indexing

The market has 65,536 discrete ticks. Occupancy is represented by 256 leaf bitmap words, each covering 256 ticks, plus one 256-bit top-level word marking non-empty leaf words.

Best bid and ask discovery is therefore bounded and does not require a tree of storage nodes.

## Tick pool

Each active side/tick has exact integer remainingLots, totalShares, a cumulative fillIndexX96 for lazy maker attribution, a carried division remainder, and a generation counter.

Taker fills mutate aggregate tick state and never touch maker storage.

## Maker shares

A maker owns shares of one side/tick pool. Late makers mint at the current totalShares / remainingLots ratio and checkpoint the current fill index, so they do not inherit historical fills.

Cancellation burns shares and redeems the maker's current pro-rata share of unfilled integer lots. There are no linked-list nodes, tombstones, or stale-order cleanup.

## Generation rollover

If a taker fully depletes a pool, the pool stores a compact closed-generation record containing the terminal fill index and outstanding shares. The hot pool immediately rolls to a new generation.

A maker from the closed generation settles lazily later. Once all old shares have settled, the terminal record is deleted.

## Risk envelope

Resting maker liquidity expands an account's reachable position interval. Bids increase maxPosition and asks decrease minPosition.

Fills do not mutate this envelope. Settlement materializes the exact filled position. Cancelling remaining liquidity shrinks the envelope.

The current contract tracks the envelope but does not yet enforce collateral or oracle-priced initial margin. Those are the next risk-layer components.

## Conservation and rounding

remainingLots is exact integer state. Taker fills therefore never depend on fixed-point rounding.

The fill index is only an attribution mechanism. Fractional maker claims are carried with per-maker remainders while a quote remains active. Sub-lot dust forfeited when a quote exits is tracked separately as protocol dust.

## Current scope

Implemented:
- fully on-chain liquidity state
- 65,536-tick hierarchical bitmap
- best-price matching
- IOC and FOK
- pro-rata same-price fills
- O(1) maker add/cancel relative to maker count
- lazy maker settlement
- generation rollover
- exposure-envelope accounting
- fuzz/property tests
- gas ceilings
- Ethereum mainnet-fork CI

Not yet implemented:
- token custody and settlement transfers
- fees
- collateral enforcement
- oracle/mark-price execution bounds
- funding accumulators
- liquidation
- conditional orders
- stop, take-profit and trailing orders
- OCO and brackets
- reduce-only
- multi-market portfolio margin

The next milestone should add collateral reservation and an oracle-bounded execution rule while preserving zero maker writes on the taker path.

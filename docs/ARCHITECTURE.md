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

Each active side/tick is a one-slot pool containing totalShares, exact integer remainingLots, and a generation counter.

Taker fills decrease remainingLots and update one aggregate funding-entry accumulator for that tick. They still never touch maker storage.

## Maker shares

A maker owns shares of one side/tick pool and stores a materialized claimLots value. Late makers mint at the current totalShares / remainingLots ratio.

A maker's pending fill is derived lazily from the loss in redeemable pool assets: last materialized claimLots minus the maker's current pro-rata redeemable lots. Cancellation first settles that loss, then burns shares and redeems current unfilled lots. There are no linked-list nodes, tombstones, or stale-order cleanup.

## Generation rollover

If a taker fully depletes a pool, remainingLots becomes zero, totalShares is cleared, the generation increments, and the tick is removed from the occupancy bitmap.

Funding uses a compact terminal accumulator keyed by tick and generation so makers from the completed generation can settle later. The terminal accumulator is deleted once all outstanding shares from that generation settle.

## Risk envelope

Resting maker liquidity expands an account's reachable position interval. Bids increase maxPosition and asks decrease minPosition.

Fills do not mutate the maker account on the taker path. Settlement materializes the exact filled position and tightens the envelope:
- settled bid fills move minPosition upward;
- settled ask fills move maxPosition downward.

Cancelling remaining liquidity also shrinks the envelope.

## Collateral reservation and oracle execution bounds

Once risk is enabled:

- makers must hold enough collateral to reserve initial margin before quotes can rest;
- required margin is based on the worst absolute endpoint of the reachable position interval;
- each new tick pool receives a fixed risk ceiling derived from the current mark plus the configured execution band;
- matching only considers ticks inside the current oracle band;
- if the mark later rises above a pool's reserved ceiling, that pool remains on-chain but becomes non-executable until makers cancel/requote under a new ceiling.

This prevents an old quote from silently becoming executable under a more expensive risk regime than the one it was collateralized for.

## ERC-20 custody

Settlement can be configured with a collateral ERC-20 and mark-oracle adapter.

After configuration:
- depositCollateral transfers the configured ERC-20 into the contract;
- withdrawCollateral transfers it back out;
- fee-on-transfer style behavior is rejected by comparing the amount requested with the actual token balance delta.

The mainnet-fork test now uses real WETH: the test wraps ETH, approves the order book, deposits WETH into the contract, and then executes an order-book trade.

## Withdrawal safety

A maker with active quote positions cannot withdraw collateral while risk is enabled.

The maker must first settle/cancel those quote positions. This ensures lazy fills and their funding effects are materialized before collateral leaves the contract.

Withdrawal then checks:
- token-backed collateral balance;
- accumulated funding cashflow;
- reserved margin on the now-materialized risk state.

This is intentionally conservative.

## Lazy funding

Funding is represented by a signed global cumulative funding index.

On each taker fill:
- no maker state is updated;
- the tick receives a weighted per-share funding-entry accumulator update.

When a maker later settles:
- the maker's filled quantity is reconstructed from share-value loss;
- the weighted funding index of those fills is reconstructed from the tick accumulator;
- funding between fill-time and settlement-time is applied to fundingCashflow;
- already-materialized position funding is then accrued from the account's own funding checkpoint.

This keeps maker-count-independent matching while preserving the time dimension of funding.

The accumulator uses fixed-point arithmetic and symmetric nearest rounding for final maker attribution. Exact executable liquidity remains integer-denominated in remainingLots and is never derived from the funding accumulator.

## Conservation and rounding

remainingLots is exact integer state. Taker fills therefore never depend on fixed-point rounding.

Maker fill attribution uses vault-style share accounting. The current redeemable claim is floor(shares * remainingLots / totalShares). Rounding can create tiny share-price dust on joins/exits, but it cannot create executable liquidity because remainingLots is authoritative.

Funding attribution has its own fixed-point accumulator and does not alter executable lots.

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
- collateral reservation
- oracle execution bands
- per-pool risk ceilings
- ERC-20 collateral custody
- pluggable mark-oracle adapter
- lazy funding-entry accumulators
- active-quote withdrawal safety
- fuzz/property tests
- gas ceilings
- Ethereum mainnet fork with real WETH custody

Not yet implemented:
- fees
- trailing stops
- OTO / full bracket composition
- minimum-fill and minimum-first-fill policies
- portfolio margin / cross-market netting
- permissionless oracle adapters and stale-price validation
- production-grade token decimal normalization
- audited funding precision bounds
- liquidation incentives / insurance accounting

The next milestone should focus on richer order composition and further storage/gas optimization without changing the maker-count-independent matching property.



## Account state packing

The risk envelope uses three signed 80-bit fields:

- settledPosition;
- minPosition;
- maxPosition.

They fit in one 256-bit storage slot. Every lot-to-position conversion is checked against the int80 protocol bound before mutation.

Account metadata is separately packed into one slot:

- funding checkpoint: int128;
- active maker quote count: uint32;
- active conditional count: uint32;
- risk ceiling tick: uint16.

This reduces the number of independent mapping slots touched by quote placement, conditional placement/cancellation, funding settlement, and risk checks.

Redundant funding-checkpoint and reserved-margin writes are skipped when the stored value already equals the new value.

## Aggressive taker accounting

Aggressive fills now materialize the taker's settled position immediately.

The matcher returns both:
- filled lots;
- aggregate execution notional across all crossed ticks.

The account then receives:
- signed position delta;
- signed trade cashflow;
- funding checkpoint update;
- updated margin requirement.

This gives a mark-to-market equity identity in protocol-native tick/lot units:

equity = collateral + tradeCashflow + fundingCashflow + position * markTick

Production deployments must normalize token decimals and price scales explicitly.

## Reduce-only

takeReduceOnly caps execution at the account's currently settled opposite-side position.

For safety, reduce-only execution currently requires zero active maker quote positions because those positions may contain lazy, not-yet-materialized fills.

A reduce-only order therefore cannot cross through zero or reverse the account.

## Conditional orders

Conditional orders are stored fully on-chain. They contain:
- owner;
- side;
- trigger direction;
- trigger tick;
- worst execution tick;
- quantity;
- IOC/FOK policy;
- reduce-only flag;
- optional OCO sibling.

Anyone may call executeConditionalOrder once the on-chain mark satisfies the trigger.

Non-reduce conditional orders reserve their reachable exposure at placement. Execution consumes that pre-reserved envelope, and any unfilled IOC remainder releases its reservation.

Reduce-only conditionals do not reserve new directional risk and are capped at the owner's exact settled position.

Pairwise OCO is implemented by linking two conditional IDs. When one executes, the sibling is cancelled atomically and its reserved exposure is released.

Conditional orders now have two activation modes:

- aggressive conditional: bounded IOC/FOK execution after the trigger;
- triggered limit: after the trigger, the order first consumes executable opposite liquidity up to its limit tick, then deposits any remainder into the ordinary maker pool at the limit tick.

Triggered limits reuse the exposure reserved when the conditional was created. The taker-filled portion materializes immediately, while the resting remainder retains the unused part of the same risk envelope. If raw opposite liquidity would leave the remainder in a crossed book, activation reverts and the conditional remains active.

## Liquidation

Maintenance margin can be configured below initial margin.

Liquidation uses exact mark-to-market equity:
- ERC-20 collateral balance;
- signed execution cashflow;
- settled and pending funding;
- marked settled position.

To avoid storing an expensive per-maker enumerable order list, liquidators supply the maker tick keys and conditional IDs they want cancelled/settled. The transaction then:
1. settles and cancels those maker quotes;
2. cancels supplied conditional orders;
3. requires the account's on-chain active counts to reach zero;
4. settles funding;
5. checks maintenance health;
6. closes as much of the remaining position as available liquidity allows inside the oracle execution band.

If the final health check says the account is healthy, the entire transaction reverts, including all preceding cancellations. A liquidator therefore cannot use this path to cancel a healthy account's orders.

This keeps normal maker add/cancel operations free from an additional enumerable-order index while still permitting exact fully-on-chain liquidation.


## Minimum-fill execution

Aggressive execution now supports an explicit minimum-fill threshold.

takeMinFill first checks aggregate executable liquidity through the caller's limit tick. If less than minFillLots is available, the transaction reverts before any tick is mutated. If the threshold is available, execution proceeds as IOC and may consume up to the requested quantity.

takeReduceOnlyMinFill applies the same threshold after capping the request to the account's reducible settled position.

For a one-shot aggressive IOC, minimum-fill and minimum-first-fill are equivalent because there is only one execution attempt.

Individual maker-side minimum-first-fill or all-or-none constraints are intentionally not supported inside a shared pro-rata tick pool. Enforcing different constraints for individual makers would require inspecting individual maker state during matching or segregating liquidity into separate pool classes, which would weaken the maker-count-independent hot path.

## OTO and bracket composition

A conditional order may have up to two OTO children.

OTO children must be reduce-only exits. Linking a child makes it dormant on-chain: it is stored but cannot execute and is not counted as an active conditional until its parent has an actual fill.

When the parent executes:
- each child quantity is capped to the parent's actual filled quantity;
- the children become active;
- two children may already be linked by OCO, producing a take-profit / stop-loss bracket.

If the parent fills zero, its dormant children are cancelled. Cancelling the parent also cascades cancellation to dormant children.

The first bracket implementation deliberately tracks only the quantity filled during the parent's aggressive conditional execution. If a triggered-limit parent rests a remainder and that maker liquidity fills later, its bracket children do not automatically expand yet. Supporting that correctly requires a settlement-driven child-resize accumulator or another lazy linkage mechanism.

## Trailing-stop design boundary

Trailing stops are not implemented yet because a trustworthy fully-on-chain trailing watermark requires more than the current mark-price interface.

A correct long trailing stop needs proof of the highest oracle observation since activation; a short trailing stop needs the lowest. Updating every trailing order whenever the mark changes would be prohibitively expensive, while letting an off-chain keeper assert the high/low would reintroduce trusted trigger evaluation.

The intended next design is an extrema-capable oracle adapter that can prove high/low since an observation identifier. A trailing order would store only:
- activation observation ID;
- trail distance;
- side;
- quantity / execution policy.

At execution, the contract would derive the watermark from the oracle's on-chain observation history rather than maintaining per-order watermark writes.

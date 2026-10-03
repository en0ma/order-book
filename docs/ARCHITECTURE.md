# Architecture

This repository implements a production-bound fully on-chain derivatives order book optimized around one defining constraint:

Taker execution should scale with the number of price levels crossed, not the number of makers filled.

## Matching rule

The deployable order book uses best-price priority across ticks and pro-rata allocation among all makers at exactly the same tick.

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

Implemented in the deployable architecture:
- fully on-chain liquidity, matching, custody, funding, fees/rebates and insurance accounting
- 65,536-tick hierarchical bitmap with best-price matching
- pro-rata same-price fills with maker-count-independent taker execution
- lazy exact maker attribution, generation rollover and explicit rounding residual accounting
- IOC/FOK, reduce-only and minimum-fill aggressive execution
- conditional stop/take-profit execution and triggered limits
- OCO, OTO/bracket composition with lazy maker-fill resize
- extrema-oracle trailing stops
- GTD expiry with permissionless advanced-order cleanup
- exposure-envelope margin, oracle execution bands and per-pool risk ceilings
- shared-collateral portfolio admission, conservative cross-market margin and portfolio liquidation
- ERC-20 custody, realized-PnL withdrawals, fee/insurance settlement and terminal bad-debt coverage
- fuzz/property/state-machine tests, gas ceilings, strict bytecode budgets and Ethereum mainnet-fork custody tests

Production hardening still required before deployment:
- independent security audits and remediation
- deployment/configuration validation and operational runbooks
- emergency/guardian controls with narrowly defined authority
- production token decimal/price-scale normalization
- oracle liveness/failure-mode hardening for deployment-specific adapters
- broader adversarial invariant, fork and long-horizon economic testing

Advanced-order roadmap:
- post-only maker admission
- iceberg/display-quantity orders with deterministic replenishment
- scheduled/TWAP-style execution
- additional composition primitives that remain outside the maker-count-independent matching hot path


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
- active trailing count: uint32;
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

Triggered-limit parents can now keep a resting maker share slice linked to their OTO children. Taker matching still mutates only aggregate tick state. When the maker later settles, or when the advanced-order module explicitly syncs the parent, the module derives the additional filled quantity from the share slice and expands the reduce-only children lazily. Executing an exit first syncs the entry and cancels any still-resting entry remainder before closing the position.

## Trailing stops

Trailing stops use a separate extrema-capable on-chain oracle interface.

A trailing order stores:
- activation observation ID;
- trail distance in ticks;
- side;
- limit tick;
- quantity;
- IOC/FOK policy;
- reduce-only flag.

The order itself does not receive watermark updates. At execution the contract asks the extrema oracle for the highest and lowest observed ticks since the stored observation ID.

For a trailing sell, execution is allowed when currentTick + trailTicks <= highSinceActivation.

For a trailing buy, execution is allowed when currentTick >= lowSinceActivation + trailTicks.

This keeps trigger truth on-chain without one storage write per trailing order whenever the market moves.

The repository includes SegmentTreeExtremaOracle, a bounded 4,096-observation ring-backed segment tree. Appends and high/low range queries are O(log N). Observations older than the retained window expire. Tick zero is preserved by encoding tick+1 in the tree so zero can remain the empty-node sentinel. The updater is the authoritative mark publisher; trigger execution remains permissionless.

Trailing orders participate in withdrawal safety and liquidation cleanup. liquidateWithTrailing can atomically cancel supplied trailing IDs before the maintenance-health check; if the account is healthy the entire transaction, including those cancellations, reverts.


## Deployable core/module split

The feature-complete ProRataOrderBook contract is retained as a reference implementation, but it is not deployable on Ethereum mainnet because its runtime bytecode exceeds EIP-170.

Measured runtime sizes demonstrated the problem:
- reference monolith, default optimizer profile: about 53.2 KB;
- reference monolith, size profile: about 40.6 KB;
- EIP-170 limit: 24,576 bytes.

The production-oriented architecture separates the protocol into specialized deployable contracts.

### OrderBookCore

OrderBookCore contains only the hot and safety-critical shared state:
- tick bitmap and matching;
- pro-rata pools and maker shares;
- ERC-20 custody;
- risk envelopes and initial-margin reservation;
- signed execution cashflow;
- immutable taker-fee / maker-rebate accounting;
- lazy funding;
- direct maker add/cancel/settle;
- direct IOC/FOK taker execution as the minimal user-facing matching primitive;
- immutable collateral token, mark oracle, execution band, and initial-margin configuration;
- one immutable-after-configuration advanced-module address.

The module receives narrow authorized capabilities rather than arbitrary delegatecall access. It can reserve/release exposure, execute on behalf of an account, create pre-reserved resting liquidity, settle an account/tick, and remove only module-locked maker shares.

Module-created maker shares are explicitly locked in the core. Generic maker cancellation can burn only unlocked shares. This allows multiple advanced resting orders to share the same maker/side/tick pool while preserving each module order's independently tracked share slice.

### AdvancedOrderModule

AdvancedOrderModule owns generic advanced-order state:
- direct reduce-only and atomic minimum-fill wrappers;
- stop/take-profit conditionals;
- triggered limits;
- OCO;
- OTO/brackets;
- lazy bracket resize;
- trailing orders.

It is also the single core-authorized gateway for specialized modules. The core therefore keeps one narrow trust boundary rather than a dynamic module registry.

### MarketMakerModule

MarketMakerModule owns managed market-maker quote metadata and batching policy.

Canonical liquidity still lives in OrderBookCore. The MM module calls authenticated forwarding functions on AdvancedOrderModule, which in turn invokes the core's narrow module hooks.

Managed share locks are generation-bound. A stale lock from a fully consumed generation can be unlocked as a no-op without touching a new quote created later at the same maker/side/tick.

For target refreshes:
- unchanged same-generation targets preserve the existing share slice;
- increases preserve the slice and add only the missing lots;
- decreases remove and rebuild the managed slice so integer share rounding cannot leave the wrong executable lot amount;
- batch exposure reservation is aggregated once per side.

### LiquidationModule

LiquidationModule owns maintenance-margin policy and orchestration.

AdvancedOrderModule retains only storage-aware cleanup for its conditional/trailing/resting state plus narrow authenticated forwarding into OrderBookCore. This keeps liquidation policy out of the generic advanced-order bytecode while preserving atomic cleanup.

### SegmentTreeExtremaOracle

The extrema oracle is separate from both order contracts and provides bounded historical high/low queries for trailing stops.

### Bytecode budget

The deployable contracts are compiled with the Foundry size profile (optimizer_runs = 1).

Current measured size-profile runtime sizes:
- OrderBookCore: about 21,511 bytes;
- AdvancedOrderModule: about 18,617 bytes;
- MarketMakerModule: about 4,434 bytes;
- LiquidationModule: about 4,001 bytes;
- SegmentTreeExtremaOracle: about 2,152 bytes.

CI intentionally enforces stricter project budgets than EIP-170:
- OrderBookCore <= 22,000 bytes;
- AdvancedOrderModule <= 19,500 bytes;
- MarketMakerModule <= 5,000 bytes;
- LiquidationModule <= 5,000 bytes;
- SegmentTreeExtremaOracle <= 4,000 bytes.

This prevents gradual bytecode creep from consuming all deployment margin. The oversized reference monolith remains compiled and tested but is deliberately excluded from the deployable size gate.


## Modular liquidation

Maintenance policy and liquidation orchestration live in LiquidationModule.

AdvancedOrderModule exposes only:
- advanced-order cleanup over supplied conditional/trailing IDs;
- a force-cancel forwarding hook for supplied maker ticks;
- a reduce-only liquidation execution hook.

LiquidationModule checks core quote count plus advanced-order count, reads marked equity and settled position directly from OrderBookCore, computes the maintenance requirement, and requests the final reduce-only close through the authenticated gateway. If the account is healthy, the entire cleanup and liquidation transaction reverts.

Advanced resting share slices are reconciled before generic core quote cleanup so bracket-linked locks cannot be deleted before their module state is settled.


## Abstraction rules

The deployable code follows four boundaries.

1. **Core primitives, not product features.** OrderBookCore owns canonical book state, matching, maker-share accounting, custody, margin and funding. It exposes IOC/FOK matching plus narrow module capabilities. Reduce-only convenience flows, minimum-fill policy, conditional semantics, brackets, trailing stops and liquidation live outside the core.

2. **Canonical storage getters.** Modules consume Solidity's generated getters for canonical mappings such as pools, quotes and accountRisk rather than adding duplicate wrapper methods to the core.

3. **Shared pure semantics.** OrderBookMath centralizes side inversion, price-limit comparison, bounded tick arithmetic, signed-position absolute value and share redemption. Storage-heavy matching/bitmap logic intentionally remains internal to the core so abstraction does not introduce external-call overhead on the hot path.

4. **Immutable market configuration.** The deployable core receives collateral token, mark oracle, execution band and initial-margin parameters in its constructor. The research monolith retains flexible configuration for experiments, but production runtime does not carry optional token/oracle/risk branches.

Atomic minimum-fill is implemented in AdvancedOrderModule by calling the core IOC primitive and reverting if the returned fill is below the threshold. Because the entire cross-contract transaction reverts, partial core mutations are rolled back without requiring a second liquidity-scanning primitive in the core.


## Oracle source binding

AdvancedOrderModule verifies at construction that its extrema oracle is exactly the same contract exposed by OrderBookCore as the immutable mark oracle.

That is stronger than checking whether two independent sources happen to return the same current tick. Historical trailing-stop extrema and execution-band pricing therefore share one authoritative observation stream by construction. The redundant per-execution equality check was removed after this invariant moved to deployment time.


## Market-maker batching and scaling

Managed quote refresh is intentionally separate from the matching engine.

The batch API uses target remaining lots rather than cancel/add instructions. For each managed maker/side/tick slice it first derives the current executable lots from the slice's shares and the aggregate tick pool.

If the target is unchanged, no liquidity mutation is needed. If the target increases, only the delta is reserved and added. If the target decreases, the slice is removed and rebuilt to the exact target because partial share redemption is integer-rounded.

Risk reservation is aggregated across the batch and performed once per side.

Quote records must be strictly sorted by side/tick key and unique inside a batch. This makes duplicate-target behavior impossible and keeps validation O(N).

The market-maker module exposes both:
- a typed QuoteUpdate[] ABI for normal integrations;
- a packed bytes ABI for latency/calldata-sensitive integrations.

Both normalize into the same internal uint128 representation and the same refresh engine.

Packed record layout:
- bits 0..95: lots;
- bits 96..111: tick;
- bit 112: side (0 bid, 1 ask);
- bits 113..127: reserved and required to be zero.

Each packed quote is therefore exactly 16 calldata bytes. For a 16-level refresh, total function calldata is 324 bytes versus 1,604 bytes for the typed ABI, a 79.8% reduction. Execution gas remains effectively unchanged because the same storage/risk work is performed; the optimization targets calldata cost and rollup data footprint.

The dedicated deployable gas-regression suite covers 1, 4, 8 and 16 managed quote levels. Current total test gas is approximately:
- 1 level: 402k;
- 4 levels: 1.01m;
- 8 levels: 1.74m;
- 16 levels: 3.20m.

Those figures include the test's initial quote setup plus refresh call, so they are regression/scaling measurements rather than isolated transaction gas. A separate regression asserts that one four-level batch replacement is cheaper than four one-level replacement calls.


## Packed codec headroom decision

The fixed-width 16-byte quote codec intentionally stops short of an on-chain delta-tick codec.

A denser sorted-tick format could reduce the raw record width further, but for a representative 16-level batch the current packed function already uses 324 total calldata bytes. Because dynamic bytes are ABI-padded to 32-byte boundaries, modest sub-16-byte record reductions often save only one additional 32-byte calldata word at this batch size.

MarketMakerModule is currently about 4,434 bytes against a 5,000-byte project budget. Spending most of the remaining module budget on another decoder is therefore a poor trade relative to the incremental calldata reduction. Future delta/grid compression should preferably live in an SDK or a separately budgeted codec path unless measurements show a materially better end-to-end result.


## Adversarial deployable state-machine testing

The deployable contracts now have a dedicated randomized sequence harness in addition to focused unit tests.

Each fuzz seed runs a sequence mixing:
- managed quote create/resize/cancel;
- ordinary maker add/remove;
- IOC taker fills;
- maker settlement;
- funding-index changes;
- oracle moves;
- two-level managed quote batches.

Expected operation reverts are tolerated. Canonical invariants are checked after every attempted transition, so a reverting action cannot hide partial state corruption.

Current state-machine invariants include:
- minPosition <= settledPosition <= maxPosition for every tracked account;
- reserved margin <= collateral;
- activeQuoteCount exactly matches tracked nonzero maker quotes;
- pool totalShares is zero iff remainingLots is zero;
- pool generation never regresses;
- maker quote generation never exceeds pool generation;
- current-generation maker shares never exceed pool totalShares;
- the sum of all tracked current-generation maker shares exactly equals pool totalShares.

The fuzz configuration runs 5,000 independently seeded 12-step sequences. A separate deterministic corpus adds longer 32-step sequences while staying below Forge's single-test gas ceiling.

This harness intentionally mixes ordinary maker shares and MarketMakerModule-managed shares at the same ticks, because generation rollover and locked-share ownership are high-risk composition boundaries.


## Fee and rebate accounting

Fee accounting is part of OrderBookCore because it changes canonical account cashflows. Fee policy is intentionally minimal and immutable so it does not become another runtime governance branch.

The constructor receives:
- takerFeeBps;
- makerRebateBps.

Both are bounded to 10,000 bps and makerRebateBps must be less than or equal to takerFeeBps. Fixing the schedule at deployment avoids a subtle retroactivity problem: if fees could change while maker fills were still unsettled, a later maker settlement could otherwise apply a new rebate rate to an old fill.

### Taker path

After matching returns aggregate executed notional, the taker cashflow is updated once:

- bid taker: -(notional + takerFee);
- ask taker: +(notional - takerFee).

The core also increments protocolFeesAccrued by:

    takerFee - reservedMakerRebate

where reservedMakerRebate is computed from the same executed notional.

This introduces no maker read/write and no external fee-policy call into matching.

### Maker path

Maker rebates materialize lazily during maker settlement.

Because a maker quote belongs to exactly one tick, settled maker notional is:

    filledLots * tick

The rebate can therefore be derived at settlement without a separate per-fill fee accumulator:

    makerRebate = floor(makerNotional * makerRebateBps / 10_000)

The rebate and maker trade notional are folded into one tradeCashflow storage write.

### Rounding policy

The taker path reserves the aggregate maker rebate before makers are individually materialized. Individual maker rebate calculations floor independently, so actual credited maker rebates may be slightly smaller than the reserved amount.

The protocol deliberately treats that difference as conservative dust:
- maker rebates cannot exceed the reserved rebate;
- protocol fee accounting plus credited maker rebates cannot exceed the taker fee;
- dust remains in contract backing rather than being assigned to either party.

FeeAccountingPropertyTest fuzzes three pro-rata makers for 5,000 runs and asserts those inequalities.

### Current boundary

protocolFeesAccrued is accounting-only. Protocol-fee withdrawal, fee-recipient routing, insurance-fund allocation, and rebate tiers are not implemented yet.

The current recurring fee gas regression compares identical zero-fee and fee-enabled takes after the fee-accrual slot has been initialized and requires recurring fee overhead to remain below 20,000 gas.

## State-machine regression found by fuzzing

The adversarial deployable state machine caught a direct-Ask risk-envelope regression introduced during fee cashflow optimization.

The optimized Ask taker branch had accidentally dropped the non-pre-reserved minPosition shift. A direct sell from flat could therefore produce:

    settledPosition = -13
    minPosition     = 0
    maxPosition     = -13

violating minPosition <= settledPosition.

The missing minPosition update was restored and a focused direct-Ask regression was added. The full randomized state-machine corpus is green again. This validates the value of checking risk-envelope invariants after every randomized transition rather than relying only on scenario tests.

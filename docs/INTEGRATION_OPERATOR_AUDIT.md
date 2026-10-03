# Integration and Operator Surface Audit

This document audits the deployable CLOB from the perspective of teams building a derivatives DEX on top of it.

The protocol kernel is intentionally optimized for authoritative on-chain matching, accounting, risk and custody. Integrators still need a stable product surface around that kernel: trading APIs, indexers, keepers, market-maker infrastructure, liquidation automation, observability and recovery.

The goal is to make those integrations easy without adding enumerable storage or convenience writes to the matching hot path.

## Design rule

Integration ergonomics must not weaken the core scaling invariant:

- taker cost scales with price levels crossed, not makers filled;
- maker fills remain lazy/pro-rata;
- no maker writes are added to the taker matching loop;
- no O(markets) portfolio loop is added to matching;
- integration conveniences belong in events, view-only lens contracts, SDKs and reference services unless they are required for protocol safety.

The intended stack is:

```
OrderBookCore
    |
protocol modules
    |
events + IntegrationLens
    |
indexer / keeper / SDK
    |
DEX backend / API / trading UI / market maker
```

## Executive findings

### Strong today

The deployable contracts already provide:

- authoritative on-chain liquidity and matching;
- deterministic pool and quote getters;
- explicit trade, liquidity, funding and collateral events;
- permissionless conditional, trailing and expiry execution;
- atomic OCO/OTO/bracket semantics;
- permissionless liquidation entrypoints;
- typed and compact packed market-maker quote refresh;
- portfolio-aware admission and liquidation;
- deterministic generation-bound managed maker slices;
- oracle-backed trigger verification;
- exact lazy maker attribution.

These are sufficient to build integrations.

They are not yet sufficient to make integration simple, uniform and hard to get wrong.

### Main gap

The current on-chain execution surface is stronger than the integration surface.

A production DEX team should not need to understand generation rollover, locked maker shares, lazy materialization, OTO storage graphs or standalone-versus-portfolio routing merely to implement:

- an order ticket;
- an open-orders page;
- a positions page;
- an L2 book;
- a keeper;
- a liquidation bot;
- a market-making daemon;
- crash recovery.

The missing layer should be built around the kernel rather than inside it.

## Priority matrix

### P0: lifecycle and reconstruction correctness

1. Terminal GTD metadata must be cleared on every terminal lifecycle path.
2. Event semantics must allow an indexer to reconstruct active/terminal advanced orders without storage archaeology.
3. A canonical event ordering and reorg recovery specification must be published.
4. Liquidation/indexer requirements for supplying maker ticks and advanced-order IDs must be explicit and testable.
5. Lazy maker fills must have a canonical effective-state interpretation for UIs and risk dashboards.

### P1: integration ergonomics

1. Add a view-only `IntegrationLens`.
2. Add explicit market-maker lifecycle/recovery events and views.
3. Publish a TypeScript SDK with one product-level API over standalone and portfolio deployments.
4. Publish a reference indexer schema and replay algorithm.
5. Publish reference keeper loops for triggers, expiries, resting sync and liquidation.
6. Publish a deployment manifest schema.

### P2: operator quality

1. Add health/diagnostic views for oracle freshness, configured module addresses and deployment parameters.
2. Add integration state-machine tests for replay, restart, reorg and keeper downtime.
3. Add reference API/WebSocket response schemas.
4. Add metrics/runbook guidance for keepers, liquidators and market makers.

## 1. Indexer audit

### Current source of truth

Canonical state is distributed across:

- `OrderBookCore` pools, quotes, account risk and accounting;
- `AdvancedOrderModule` advanced orders and composition state;
- `MarketMakerModule` managed share metadata;
- portfolio modules for shared collateral/risk;
- oracle observations.

Events already cover much of the lifecycle.

### Required canonical ordering

Reference indexers should process logs using:

```
(chainId, blockNumber, transactionIndex, logIndex)
```

Market identity must include the deployment address set, not a human market symbol.

For finality-sensitive deployments, the indexer should maintain:

- a provisional head;
- a finalized checkpoint;
- block hash per processed height;
- rollback support to the last common ancestor.

### Snapshot + delta model

The reference indexer should support deterministic rebuild from:

1. deployment manifest;
2. a known finalized block;
3. contract view snapshots for canonical aggregate state;
4. ordered event deltas after that block.

The protocol should not store an enumerable global order list merely to make snapshots convenient.

### Required indexed entities

At minimum:

- markets;
- tick pools;
- maker quote slices;
- trades;
- accounts;
- advanced conditional orders;
- trailing orders;
- OCO/OTO links;
- resting advanced parents;
- GTD expiries;
- managed MM quotes;
- portfolio locks/collateral;
- liquidation attempts/results;
- oracle observations.

### Lazy maker fill semantics

A maker quote may be economically filled before the maker's account storage is materialized.

A UI/indexer therefore needs two concepts:

- **materialized state**: current account storage;
- **effective state**: materialized state plus deterministic pending maker attribution.

The integration layer must never present lazy settlement as “no fill happened”.

A lens or reference indexer should expose:

- pending filled lots by maker quote;
- effective settled position;
- pending trade cashflow;
- pending funding attribution;
- remaining executable maker claim.

The exact formulas must reuse the same share/generation semantics as the contracts.

## 2. Trading UI and backend API audit

A DEX backend should expose product-level actions, not contract-routing details.

Recommended SDK surface:

```ts
placeLimit(...)
placeMarketableLimit(...)
placePostOnly(...)
placeReduceOnly(...)
placeStop(...)
placeTriggeredLimit(...)
placeBracket(...)
placeTrailing(...)
setExpiry(...)
cancelOrder(...)
syncOrder(...)
deposit(...)
withdrawAvailable(...)
replaceQuotes(...)
liquidate(...)
```

The SDK should route internally through:

- Core for standalone primitive actions;
- AdvancedOrderModule for advanced execution;
- PortfolioAdmissionCoordinator for portfolio-mode risk growth;
- MarketMakerModule for managed quotes.

### Read API

Recommended high-level reads:

```ts
getMarket()
getBook(depth)
getBestBidAsk()
previewTake(...)
getAccount()
getOpenOrders()
getOrder(id)
getPositions()
getAvailableToWithdraw()
getLiquidationHealth()
```

These APIs should be implementable from an `IntegrationLens` plus the indexer.

## 3. IntegrationLens specification

Status: first bounded on-chain lens implementation is now present in `src/deployable/IntegrationLens.sol`; the sections below remain the target contract as the surface expands.

The lens must be a separate view-only contract so integration convenience does not consume Core bytecode or matching gas.

Recommended first surface:

### Market state

- current mark tick;
- oracle freshness metadata;
- best bid / best ask;
- N levels of aggregate depth from a starting tick;
- pool state for a batch of ticks;
- executable lots through a limit tick;
- immutable/configured market parameters.

### Account state

- materialized position;
- min/max risk envelope;
- effective equity;
- collateral / shared collateral claim;
- reserved margin / portfolio requirement;
- active core quote count;
- active advanced count;
- withdrawable settled cash estimate.

### Maker state

For a supplied set of quote keys:

- generation;
- shares;
- current claim;
- estimated pending filled lots;
- lock/managed status where applicable.

### Advanced-order state

For supplied IDs:

- order kind;
- active / dormant / resting / terminal status;
- owner;
- trigger data;
- limit;
- quantity;
- reduce-only;
- post-only;
- expiry;
- OCO sibling;
- OTO parent/children;
- resting-link status and cumulative fill.

The lens should accept bounded caller-supplied arrays rather than maintaining protocol-owned enumeration.

## 4. Keeper audit

Permissionless execution is already a strong base.

A production keeper should maintain four work queues.

### Trigger queue

Tracks active:

- conditionals;
- triggered limits;
- trailing orders.

Execution is attempted only when local simulation against the current canonical mark says the trigger is satisfied.

### Expiry queue

Tracks GTD orders by expiry timestamp.

At or after expiry:

- call permissionless expiry cleanup;
- retry across transient RPC/reorg failures;
- treat an already-terminal order as success after canonical resync.

### Resting-parent sync queue

Triggered-limit parents with OTO children need periodic/event-driven sync so UI state and child sizing converge without relying on the owner.

Sync should be prioritized when:

- the underlying pool changed;
- a child is near trigger;
- the account approaches liquidation;
- the DEX UI requests exact current bracket size.

### Liquidation queue

Tracks accounts whose indexed effective equity approaches maintenance requirement.

Before submitting liquidation:

- resolve all maker tick keys;
- resolve all advanced order IDs;
- refresh oracle state;
- simulate the full liquidation call;
- submit only against the expected deployment/configuration.

The requirement to supply order keys is deliberate: it keeps normal order placement free of enumerable-list storage.

## 5. Market-maker audit

The packed quote refresh API is suitable for latency-sensitive MMs.

Status: canonical managed-quote recovery events and the `managedQuote` recovery getter are implemented. Event replay tests now prove that add/increase/decrease/cancel and generation-rollover transitions reconstruct the same managed state as the canonical getter.

Remaining ergonomics outside the hot path:

- a canonical packed-record encoder in the SDK;
- a reconciliation helper that compares target quotes against indexed/on-chain managed state;
- restart procedure: load last finalized state, query the canonical recovery getter for target keys, replay finalized quote events after the checkpoint, then send one atomic target refresh;
- broader replay/reorg tests spanning Core, advanced-order and portfolio events.

MM infrastructure should treat `batchReplaceQuotes*` as target-state convergence, not imperative cancel/add commands.

## 6. Liquidator audit

Liquidation correctness depends on a reliable off-chain registry of:

- active maker ticks;
- advanced conditional IDs;
- trailing IDs;
- portfolio markets.

That registry should be part of the reference indexer.

A liquidator should never rely solely on stale database state. Immediately before submission it should:

1. query active counts;
2. fetch supplied keys from the indexer;
3. simulate liquidation;
4. resync if `UnsettledOrders` or lifecycle drift is detected.

## 7. Deployment manifest

Every deployment should publish a machine-readable manifest containing at least:

- schema version;
- chain ID;
- market ID;
- Core address;
- AdvancedOrderModule address;
- MarketMakerModule address;
- LiquidationModule address;
- portfolio policy/vault/coordinator addresses when enabled;
- oracle address;
- collateral token address and decimals;
- tick/lot/accounting scale;
- execution band;
- margin parameters;
- fee/rebate configuration;
- oracle freshness configuration;
- deployment block;
- ABI/package version.

The SDK/indexer should initialize from this manifest rather than hard-coded addresses.

## 8. Event contract

Events are a public integration API and should be treated as versioned protocol surface.

Rules:

- every terminal lifecycle transition must be observable;
- specialized semantics such as post-only must not be hidden behind generic placement events;
- event fields should not require reading historical storage to interpret the transition;
- additions are preferred over mutating established event signatures when compatibility matters;
- reference reconstruction tests should replay events into a model and compare against on-chain views.

## 9. Failure and recovery tests

Status: deterministic replay coverage now includes aggregate Core pool state, checkpoint-plus-delta recovery, advanced conditional terminal lifecycle reconstruction, duplicate-delivery idempotence for set/delete lifecycle reducers, portfolio lock reconstruction, and managed-MM quote replay. Reorg rollback and broader multi-market/keeper downtime scenarios remain.

Add an integration-focused state machine separate from economic invariants.

Scenarios:

- indexer process crash and replay;
- duplicate log delivery;
- short reorg and rollback;
- keeper downtime across trigger and expiry boundaries;
- MM process restart with stale local target state;
- lazy maker fill before backend restart;
- generation rollover during downtime;
- OCO/OTO cascade during replay;
- liquidation racing user cancellation;
- portfolio account mutation across multiple markets;
- oracle stale/fresh transitions;
- API resync from finalized snapshot plus deltas.

Implemented recovery coverage now includes:
- aggregate book reconstruction from a canonical checkpoint plus event deltas;
- duplicate set/delete lifecycle delivery;
- short-reorg rollback using Foundry state snapshots, with orphaned deltas discarded and canonical-branch deltas replayed from the same checkpoint;
- advanced-order restart recovery after a reorg, including GTD state.

Remaining recovery work includes multi-market portfolio rollback and keeper-downtime/resubmission scenarios.

Invariant:

> Replaying finalized protocol events from a valid checkpoint must reconstruct the same externally relevant state as canonical on-chain reads.

## 10. Recommended implementation order

1. Fix terminal GTD metadata cleanup.
2. Define and test canonical advanced-order lifecycle states.
3. Add MM lifecycle events/recovery views.
4. Implement `IntegrationLens`.
5. Add replay/reorg integration tests.
6. Publish TypeScript SDK and deployment manifest schema.
7. Publish reference indexer.
8. Publish reference keeper/liquidator services.
9. Add WebSocket/API examples on top of the reference indexer.

## Non-goals

Do not add:

- global enumerable maker-order arrays to Core;
- per-maker writes in the taker loop;
- generic delegatecall plugin systems;
- UI-specific storage to matching contracts;
- indexer convenience state that weakens gas scaling.

The integration layer should make the protocol easy to use while preserving the minimal, predictable execution kernel.

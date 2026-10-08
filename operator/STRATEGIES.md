# Strategy operation and recovery

The optional strategy module supports iceberg refresh, TWAP slice execution, and pegged-quote repricing. This operator extension closes the event authentication and keeper-planning gap without changing Core matching.

## Event ingestion

Validate the deployment manifest with an `executionStrategy` address for each strategy-enabled market. The canonical bridge authenticates the five strategy lifecycle events against that address. Never accept those events from Core or Advanced. The manifest identity includes this address, so changing it invalidates old operator checkpoints.

Feed normalized strategy events into `StrategyRegistry.applyBatch` only after obtaining a canonical, ordered block. The batch is atomic. Keep snapshots with the same confirmed block/hash metadata as the operator checkpoint and restore both registries to the same ancestor on reorg. Do not treat a strategy registry snapshot as a chain-verified checkpoint on its own.

## Keeper read-before-write

On each safe head, retrieve current on-chain observations for every registry entry (active, remainingLots, visibleLots, nextExecution, currentTick), and pass these to `planStrategyTasks` with a chain-derived timestamp and market marks. Missing observations fail closed: no task is generated. A TWAP slice must not be presumed executed based on its placement event; future quantity is admitted only when executing the slice. Pegged tasks must be simulated to enforce the on-chain bid/ask price-bound semantics before submission.

Keep idempotency keys stable at a canonical branch epoch, simulate the exact call before submitting, and re-observe chain state after successful inclusion. Liquidation calls must still include strategy IDs, and strategy-aware forced cleanup is authoritative for contaminated quotes.

## Integration boundaries

`operator/strategies` exports a standalone registry, JSON-safe snapshot/restore, and task planner. Operators supply the RPC reads, persistence, reorg coordination, and transaction submission adapters. These are deliberately not silently inferred from historical events. Do not expose unverified derived fills as final account positions.

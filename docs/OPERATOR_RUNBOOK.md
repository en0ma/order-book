# Self-Hosted Operator Runbook

This runbook is for protocol teams that fork this repository and operate their own DEX deployment.

The reference operator remains transport-neutral. Your team supplies RPC access, event decoding, persistence, simulation, signing and transaction submission. The repository supplies deterministic replay, keeper planning, bounded reorg recovery and production-oriented runtime primitives.

## Startup gate

Before starting keepers or accepting public traffic:

1. Load the deployment manifest your team published for this deployment.
2. Run the SDK deployment verification plan against the target RPC.
3. Use `verifyDeploymentOrThrow` (or equivalent fail-closed handling) so a chain mismatch, missing bytecode, wrong module wiring, wrong admin/funding authority or read failure prevents startup.
4. Create the operator indexer with a reorg window appropriate for the chain.
5. Load the persisted checkpoint only when its manifest identity matches the active deployment.
6. Start catch-up from the checkpoint head or the manifest deployment block.

Never reuse a checkpoint from another deployment, even on the same chain.

## Finality and bounded catch-up

`syncOperatorOnce` accepts:

- `confirmationDepth`: blocks withheld from canonical processing;
- `maxBlocksPerSync`: maximum canonical blocks applied in one cycle.

Use non-zero confirmation depth when your DEX prefers delayed keeper action over reacting to the chain tip. Use bounded catch-up so a long outage does not create an unbounded single process cycle.

The sync result exposes:

- remote RPC head;
- safe head after confirmation depth;
- first and last block considered in the current batch;
- applied block count;
- rollback ancestor when a retained reorg was reconciled;
- keeper tasks derived from the resulting canonical state.

## Checkpoint persistence

The Node export `@en0ma/order-book-operator/node` provides `JsonFileCheckpointStore`.

Writes are atomic: a temporary file is written and renamed over the checkpoint path. The file also records the canonical manifest identity and fails closed when opened with a different deployment identity.

For multi-instance production systems, implement `OperatorCheckpointStore` against your own transactional database or object store. The same rules apply:

- checkpoint and manifest identity must be stored together;
- only commit a checkpoint representing a fully applied canonical block;
- do not partially overwrite a valid checkpoint;
- keep database backups outside the operator process.

## Reorg recovery

The in-memory indexer retains a bounded canonical snapshot window.

On every cycle the operator compares its indexed head against the RPC canonical hash. If the head changed, it searches retained history from newest to oldest, rolls back to the latest common ancestor and replays forward.

If no common ancestor exists in retained history, the operator fails rather than guessing. Recovery is:

1. stop transaction submission;
2. discard the stale in-memory process;
3. restore a finalized checkpoint known to predate the reorg, or rebuild from the deployment block;
4. catch up again against the canonical RPC;
5. resume keepers only after deployment verification and replay succeed.

## Keeper idempotency

Every planned keeper action can be assigned a deterministic idempotency key with `keeperTaskId`.

The key binds:

- deployment identity;
- indexed canonical head number/hash;
- task kind and task-specific identifiers.

Use `executeKeeperTasksIdempotent` with an executor that records submitted keys. The executor must also simulate every task immediately before submission.

A production transaction service should treat the idempotency key as a durable unique request key. This prevents process restart, API retry or duplicate worker delivery from intentionally creating multiple submissions for the same canonical task.

After a reorg, the canonical head changes and therefore the key changes. The new branch may legitimately require a new task.

## Portfolio liquidation

Portfolio operators must provide live policy health through `getPortfolioHealth`. Replayed `PortfolioLockSynchronized` events are historical observations and are not a substitute for current policy health after oracle or funding changes.

Liquidation candidates include the maker ticks and active advanced-order IDs known to the replay state. Before submission, the liquidator should simulate the full cleanup/liquidation transaction against the current RPC state.

## Recommended process topology

A production deployment can separate:

- canonical event ingestion / checkpoint writer;
- read API / indexer replicas;
- trigger + expiry keepers;
- resting-order synchronization;
- liquidation workers;
- market-maker services;
- transaction simulation/signing/relay.

Only one component needs to own a given idempotent submission key. Multiple read replicas may independently reconstruct state from the same deployment manifest.

## Failure policy

Fail closed on:

- deployment verification mismatch;
- wrong RPC chain;
- checkpoint/deployment identity mismatch;
- reorg deeper than retained history;
- malformed decoded event metadata;
- portfolio mode without current health support;
- simulation failure.

RPC timeouts and rate limits should retry at the adapter layer. Do not convert missing data into an empty market state.

## CI

Repository CI is pull-request-only. The gate runs SDK, reference indexer and operator tests plus Solidity unit/fuzz, mainnet-fork, size and gas checks. Pushes do not independently start the full workflow.


## Diagnostics and alerting

Every operator cycle should export or log at least:

- remote head;
- configured safe head;
- indexed head;
- safe-head lag;
- blocks applied in the last cycle;
- whether a rollback/reorg occurred;
- active conditional/trailing/MM/portfolio registry counts;
- keeper task counts by kind;
- simulated/submitted/skipped transaction counts.

The reference `buildOperatorDiagnostics` helper computes the protocol-specific portion of this health record. Treat persistent non-zero safe-head lag with zero applied blocks as stalled and page the operator.

## API publication

Backends may publish `snapshotEnvelope`, `diagnosticsEnvelope`, and `tasksEnvelope` over HTTP or WebSocket. These payloads are intentionally JSON-safe and versioned.

Public APIs should expose finalized/safe state by default. If provisional state is also served, mark it explicitly and never use provisional API state as the sole source for liquidation submission.

## Audit journal

For dependency-free deployments, `JsonlOperatorAuditJournal` can persist cycle/submission/error records with restrictive file permissions. Production teams should ship or ingest these records into their standard logging/database stack and retain idempotency keys alongside transaction hashes for incident reconstruction.

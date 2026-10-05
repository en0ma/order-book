# Reference Order Book Operator

Dependency-free reference indexer/keeper primitives for teams that self-host deployments of this repository.

This package does **not** run RPC, databases, signing, transaction submission, or hosted infrastructure. Those remain the DEX operator's responsibility. It provides deterministic protocol-specific state/recovery logic that can be embedded behind viem, ethers, a custom RPC client, Postgres, Kafka, or another stack.

## Indexer model

`ReferenceIndexer` consumes normalized decoded logs in canonical order:

```
(chainId, blockNumber, transactionIndex, logIndex)
```

It reconstructs:
- aggregate pool lots/generation;
- conditional + GTD + resting lifecycle state;
- trailing lifecycle state;
- managed MM quote state;
- latest portfolio lock/equity state;
- conservative account registries useful for liquidation resync.

Blocks are committed with hash/parentHash metadata. A caller detecting a reorg calls `rollbackTo(commonAncestor)` and then applies the canonical replacement branch.

## Keeper planning

`planKeeperTasks` produces transport-neutral work items for:
- conditional execution checks;
- GTD expiry cleanup;
- resting-parent synchronization;
- trailing-order checks/expiry;
- portfolio liquidation candidates.

Liquidation registry data is intentionally conservative. Operators must query canonical on-chain counts/state and simulate liquidation immediately before submission.

## Adapter boundary

A production service should:
1. load and validate the deployment manifest;
2. decode contract logs into `NormalizedEvent`;
3. persist checkpoints/block hashes;
4. feed canonical blocks to `ReferenceIndexer`;
5. call `planKeeperTasks`;
6. simulate each action against the current chain;
7. sign/submit with the team's own keeper infrastructure.

The protocol repository does not operate a shared hosted control plane.


## Runnable adapter boundary

The operator package now includes a transport-neutral runtime boundary for wiring these primitives to a real self-hosted deployment.

`validateOperatorManifest` validates the deployment identity and market/address routing needed by an operator. `OperatorRpcAdapter` defines the RPC-facing methods the DEX team must implement:

- verify the chain ID;
- read the current head and individual canonical blocks;
- decode protocol logs into `NormalizedEvent` values;
- read current market marks;
- read current portfolio health for known accounts when portfolio mode is enabled;
- optionally provide chain time.

`syncOperatorOnce` catches an indexer up from the manifest deployment block or current checkpoint, detects a changed retained head, finds the newest retained canonical ancestor, rolls back, replays the replacement branch, then produces keeper tasks from current marks/health.

The package still does not choose an RPC library. A deployment can implement `OperatorRpcAdapter` with viem, ethers, a hosted node SDK, or an internal RPC service without changing protocol-specific replay logic.

## Keeper submission

`executeKeeperTasks` requires a `KeeperExecutor` with separate `simulate` and `submit` methods. Every task is simulated first and is only submitted if simulation succeeds.

This is deliberate: keepers should treat indexed tasks as candidates, not guaranteed transactions. Chain state may move between indexing and submission.

## Checkpoints

`ReferenceIndexer.checkpoint()` produces a JSON-safe checkpoint containing the current canonical head and protocol replay state. All bigint accounting values are serialized as decimal strings.

`restoreCheckpoint()` restores that finalized state without requiring historical log replay from genesis. Operators should persist checkpoints only after their own finality policy is satisfied. The in-memory reorg window begins again from the restored checkpoint, so a deployment should not persist an unfinalized head and expect pre-checkpoint rollback history to remain available.

A typical self-hosted loop is therefore:

1. load and validate the DEX team's deployment manifest;
2. restore the latest finalized checkpoint, if available;
3. run `syncOperatorOnce` against the team's RPC adapter;
4. persist newly finalized checkpoints in the team's own database/object store;
5. simulate and submit selected keeper tasks through the team's signer/relayer adapter;
6. repeat according to the team's own polling/subscription policy.

No hosted registry, signer, database, RPC provider, or operator service is required by this repository.

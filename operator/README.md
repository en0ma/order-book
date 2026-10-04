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

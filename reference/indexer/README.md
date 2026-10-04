# Reference indexer

This package is a dependency-free reference state/recovery core for teams operating their own deployment of the order-book engine.

It does **not** own RPC transport, ABI decoding, a database, or a hosted service. A DEX team should connect its preferred stack (for example viem/ethers + Postgres/SQLite) and feed decoded protocol logs into `ReferenceIndexer`.

## Responsibilities

The reference core provides the protocol-specific parts that are easy to get wrong:

- manifest-bound contract/address validation;
- canonical `(blockNumber, transactionIndex, logIndex)` processing;
- replay starting at the manifest deployment block;
- duplicate log/block delivery protection;
- checkpoint serialization and restart;
- parent-hash validation;
- bounded short-reorg rollback;
- aggregate pool generation/lots replay;
- conditional/GTD/resting lifecycle replay;
- OCO/OTO graph reconstruction;
- trailing-order active/expiry registry;
- managed MM quote reconstruction;
- latest portfolio lock reconstruction.

## Adapter boundary

RPC/ABI code should produce:

```ts
interface IndexedBlock {
  chainId: number;
  number: number;
  hash: string;
  parentHash: string;
  logs: ProtocolLog[];
}
```

Each `ProtocolLog` includes the emitting address plus a decoded `DecodedProtocolEvent`. The indexer checks that Core events came from the manifest Core, advanced events came from the manifest Advanced module, MM events came from the configured MarketMaker module, and portfolio lock events came from the configured coordinator.

The adapter should fetch logs beginning at `manifest.deploymentBlock`. A fresh `ReferenceIndexer` rejects a later first block to prevent silent history gaps.

## Checkpoints and restart

Persist `indexer.checkpoint()` at finalized block boundaries. The checkpoint is JSON-safe: bigint protocol values are stored as decimal strings.

On restart:

```ts
const indexer = new ReferenceIndexer(manifest, { checkpoint });
```

Then resume from exactly `checkpoint.cursor.number + 1`.

## Reorgs

The reference core keeps a bounded in-memory history (64 blocks by default). When a new block does not extend the current head, its `parentHash` must identify a retained ancestor. The core restores that ancestor snapshot, discards orphaned state/log identities, and applies the canonical sibling branch.

A reorg deeper than retained history throws. Production services should then restore the most recent finalized database checkpoint and replay canonical logs.

## Database model

The in-memory state is intentionally simple. Production adapters can persist equivalent tables for:

- pools keyed by market/side/tick;
- conditionals and trailing orders keyed by market/order ID;
- OCO/OTO links;
- managed MM quotes keyed by market/maker/side/tick;
- portfolio lock state keyed by account;
- processed block hash and log identity.

The protocol itself should not add global enumerable storage to make this easier.

## Run tests

```bash
cd reference/indexer
npm test
```

The tests cover canonical ordering, duplicate delivery, checkpoint recovery, short-reorg replacement, pool exhaustion generation rollover, triggered-limit resting/GTD semantics, OCO/OTO reconstruction, MM quote lifecycle, portfolio locks, emitter validation, and deep-reorg failure.

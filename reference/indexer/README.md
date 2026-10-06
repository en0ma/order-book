# Reference indexer

This package is a dependency-free reference state/recovery core for teams operating their own deployment of the order-book engine.

It does **not** own a hosted RPC service or database. The core remains transport-neutral, while the package now includes an optional dependency-free canonical ABI decoder and Node JSON-RPC adapter so teams do not need to rewrite protocol event decoding before they can run the reference service.

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

Persist `indexer.checkpoint()` at finalized block boundaries. The checkpoint is JSON-safe: bigint protocol values are stored as decimal strings. It also carries the bounded retained reorg window, so a restarted service can still roll back a short orphaned tip instead of losing recovery history at process restart.

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


## Node JSON-RPC + checkpoint adapter

Node services can use the optional `@en0ma/order-book-reference-indexer/node` subpath.

It provides:

- `HttpJsonRpcClient` using Node's native `fetch` for `eth_chainId`, block headers and per-block `eth_getLogs`;
- manifest-derived protocol event address filters;
- `JsonFileCheckpointStore` with atomic temporary-file + rename persistence;
- `ReferenceNodeService` for deployment-block startup, restart from persisted checkpoints, sequential canonical replay and retained-window reorg reconciliation.

The Node service still accepts a custom `ProtocolLogDecoder` for teams that use generated viem/ethers bindings, but the package also ships the canonical dependency-free decoder under `@en0ma/order-book-reference-indexer/abi`. `ReferenceNodeService.createCanonical(...)` wires that decoder automatically. Known protocol event topics are decoded strictly and malformed known events fail closed; unrelated/supplemental events are ignored.

Example:

```ts
import {
  HttpJsonRpcClient,
  JsonFileCheckpointStore,
  ReferenceNodeService,
} from "@en0ma/order-book-reference-indexer/node";

const rpc = new HttpJsonRpcClient(process.env.RPC_URL!);
const checkpoints = new JsonFileCheckpointStore("./data/indexer-checkpoint.json");
const service = await ReferenceNodeService.createCanonical(
  manifest,
  rpc,
  checkpoints,
);

await service.syncTo();
```

On every sync the adapter re-queries the connected chain ID before touching replay state. Before advancing, it rechecks the persisted head hash; if that head became orphaned, it finds a common ancestor inside the checkpoint-restored bounded retained window, rolls back, and replays the canonical replacement branch. A deeper reorg fails closed and requires restoration from a finalized checkpoint.


## Canonical ABI decoder

The `./abi` subpath exports:

- `decodeProtocolLog` / `canonicalProtocolLogDecoder`;
- `CANONICAL_EVENT_TOPICS` for the indexed Core, Advanced, MarketMaker and portfolio-coordinator lifecycle events consumed by the reference replay model.

The decoder is dependency-free and supports the protocol events required by the reference state model: aggregate liquidity/trades, conditional and trailing lifecycle, OCO/OTO/resting transitions, managed MM quote recovery, and portfolio lock synchronization.

It validates ABI word/topic shape, enum/tick/generation bounds, indexed-address padding, and signed `int256` portfolio equity. A malformed recognized event throws rather than being silently skipped.

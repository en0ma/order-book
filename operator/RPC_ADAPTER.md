# Canonical JSON-RPC operator adapter

The `./rpc-adapter` entry point connects Ethereum JSON-RPC block and log reads to the existing canonical recovery, HTTP publication, and supervised keeper boundary.

## Wire a deployment

Provide a transport that performs `eth_chainId`, `eth_blockNumber`, `eth_getBlockByNumber` and `eth_getLogs` requests. Provide a deployment-specific ABI decoder that returns `CanonicalLogEnvelope` or `undefined` for an intentionally unsupported log. Use `normalizeCanonicalEvents` through the adapter, not ad-hoc event names. A trusted mark-tick reader is required for planning; do not use old event ticks as authoritative current prices.

```js
import { createCanonicalRpcAdapter } from "@en0ma/order-book-operator/rpc-adapter";
import { createSelfHostedOperator } from "@en0ma/order-book-operator/self-hosted";

const rpc = createCanonicalRpcAdapter(transport, {
  decode: (log, chainId) => decodeUsingDeploymentAbi(log, chainId),
  markTicks: manifest => readCurrentMarkTicks(manifest),
});
const operator = createSelfHostedOperator(manifest, rpc, {
  bundlePath: "./private/canonical-recovery.json",
  auditPath: "./private/operator-audit.jsonl",
  sync: { confirmationDepth: 2, maxBlocksPerSync: 128 },
  http: { authorizeAccount },
});
await operator.bootstrap({ maxCycles: 100, listen: { port: 8080 } });
const supervisor = operator.supervise({ intervalMs: 1000, maxBackoffMs: 30000 });
const running = supervisor.run();
```

This adapter reads one block at a time and restricts log queries to addresses listed in the manifest. It checks chain identity, requested block number, log block hash and number, decoded event metadata, and the block hash again after reading logs. It sorts canonical transaction and log positions before normalization. Any mismatch fails that recovery pass; publication then closes reads and keeper admission. The supervisor can retry. An orphaned saved checkpoint still requires an operator rebuild from a trusted canonical checkpoint.

## Limits and safety

The adapter is *not* a complete ABI decoder or an RPC service. The caller must supply those integrations and handle RPC rate limits, timeouts, authenticated private reads, on-chain mark prices, signing, and transaction relay. Rechecking a block hash reduces but does not eliminate reorg races. Use a trusted RPC source, confirmation depth appropriate for the chain, external monitoring, and signer-side verification. The repository is not audited or production-ready.

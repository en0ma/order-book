# Canonical JSON-RPC operator adapter

The `./rpc-adapter` entry point connects Ethereum JSON-RPC block and log reads to the existing canonical recovery, HTTP publication, and supervised keeper boundary.

## Wire a deployment

Provide a transport that performs `eth_chainId`, `eth_blockNumber`, `eth_getBlockByNumber` and `eth_getLogs` requests. Provide a deployment-specific ABI decoder that returns `CanonicalLogEnvelope` or `undefined` for an intentionally unsupported log. Use `normalizeCanonicalEvents` through the adapter, not ad-hoc event names. Portfolio deployments using the sync/keeper cycle also need a trusted `portfolioHealth` callback for authoritative equity and maintenance requirements. A trusted mark-tick reader is required for planning; do not use old event ticks as authoritative current prices.

```js
import { createCanonicalRpcAdapter } from "@en0ma/order-book-operator/rpc-adapter";
import { createSelfHostedOperator } from "@en0ma/order-book-operator/self-hosted";

const rpc = createCanonicalRpcAdapter(transport, {
  decode: (log, chainId) => decodeUsingDeploymentAbi(log, chainId),
  markTicks: manifest => readCurrentMarkTicks(manifest),
  portfolioHealth: (accounts, manifest) => readCurrentPortfolioHealth(accounts, manifest),
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

## Production transport and log integrity

The `./http-rpc` export provides a bounded HTTP JSON-RPC transport with request timeouts, limited exponential delay for transient HTTP 408/429/5xx responses, and validation of JSON-RPC response IDs. It never retries valid JSON-RPC application errors or permanent HTTP failures. Provide an authenticated HTTPS endpoint, and keep secrets out of telemetry. Configure `maxAttempts`, `timeoutMs`, and `retryDelayMs` for the deployment.

```js
import { createHttpJsonRpcTransport } from "@en0ma/order-book-operator/http-rpc";
const transport = createHttpJsonRpcTransport(process.env.RPC_URL, {
  timeoutMs: 10000, maxAttempts: 3, retryDelayMs: 200,
});
```

Canonical ingestion also rejects logs from addresses outside the deployment manifest and duplicate transaction/log positions. A hash mismatch or orphaned persisted checkpoint still stops the cycle; this does not perform a deep-reorg rebuild. The caller must verify the full deployed ABI and event coverage.

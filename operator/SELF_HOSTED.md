# Self-hosted durable operator

This package provides a transport-neutral reference composition. It does not provide RPC, credentials, a wallet, strategy execution, or public hosting.

## Create and run

```js
import { createSelfHostedOperator } from "@en0ma/order-book-operator/self-hosted";

// Implement a trusted OperatorRpcAdapter and load your deployment manifest.
const runtime = createSelfHostedOperator(manifest, rpcAdapter, {
  bundlePath: "./private/operator/recovery.json",
  auditPath: "./private/operator/audit.jsonl",
  sync: { maxBlocksPerSync: 128, confirmationDepth: 2 },
  http: { authorizeAccount: authorizePrivateRead },
});

// Recover until the latest safe head is reached before serving data.
while (!(await runtime.recover()).readiness.ready) {}
await runtime.http.listen(8080, "127.0.0.1");
```

The recovery file contains Core index state **and** strategy registry state at one canonical hash. The store checks the deployment identity, writes to a private temporary file, syncs the file, renames it atomically, and syncs the containing directory. When it creates missing parent directories, it also syncs each new directory and its parent entry. A single process must own the file; do not run competing writers. Back up the file securely, and do not treat it as a substitute for verified on-chain state.

The audit journal path must differ from the bundle path after path normalization. The optional JSONL journal records successful recovery cycles and failures. Journal delivery is **not** transactional with the checkpoint; for regulated or critical audit needs, use a stronger external store. An audit write failure prevents `recover()` from returning normally even when a bundle has committed; the publication gate still reflects the committed ready state.

## Fail-closed rules

- Before the first ready recovery, HTTP data and keeper submission are unavailable.
- A stalled, lagging, invalid, or orphaned checkpoint leaves the runtime unavailable.
- Persisted checkpoint state is always verified against the current RPC canonical block hash before replay.
- Subsequent refresh failures close publication; operators must investigate and retry.
- The caller must authenticate private account endpoints, use TLS at the edge, and verify canonical state again in its signer.
- A deep reorg requires a trusted operator rebuild. This reference runtime does not automatically recover a deep reorg.

The library is not audited or production-ready. Tests use deterministic fake RPC blocks; integrate a trusted live RPC, monitoring, signing controls, backups, and chain-specific disaster recovery before deployment.

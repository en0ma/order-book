# Independent RPC agreement for the self-hosted operator

Use `createQuorumRpcAdapter(primary, witnesses, { required })` when operators require independent block-hash confirmation before canonical replay, HTTP publication, keeper admission, and an operator-approved orphaned checkpoint rebuild.

This wrapper composes existing `OperatorRpcAdapter` implementations, including the HTTP JSON-RPC transport and ABI decoder. It does not require a specific RPC vendor. Configure **independent** providers and do not count multiple URLs to the same backend as independent confirmation.

```js
import { createQuorumRpcAdapter } from "@en0ma/order-book-operator/rpc-quorum";
import { createCanonicalRpcAdapter } from "@en0ma/order-book-operator/rpc-adapter";
import { createHttpJsonRpcTransport } from "@en0ma/order-book-operator/http-rpc";
import { createSelfHostedOperator } from "@en0ma/order-book-operator/self-hosted";

const primary = createCanonicalRpcAdapter(
  createHttpJsonRpcTransport(primaryEndpoint), { decode, markTicks, portfolioHealth });
const witness = createCanonicalRpcAdapter(
  createHttpJsonRpcTransport(independentEndpoint), { decode, markTicks, portfolioHealth });
const quorum = createQuorumRpcAdapter(primary, [witness]);
const operator = createSelfHostedOperator(manifest, quorum, {
  bundlePath: "./private/recovery.json", auditPath: "./private/recovery-audit.jsonl",
  sync: { confirmationDepth: 2, maxBlocksPerSync: 128 },
});
await operator.bootstrap({ maxCycles: 100, listen: { port: 8080 } });
const supervisor = operator.supervise({ intervalMs: 1000 });
const supervision = supervisor.run();
```

## Canonical gate

The wrapper checks all configured chain IDs. It computes a reported head from the height reached by at least `required` providers, requiring at least two providers in agreement. For each block, the primary must have reached the height and its block hash and parent hash must match enough independent providers. The wrapper checks the same block before and after retrieving decoded primary logs. When this wrapper is passed to `createRecoveryPublication` or `createSelfHostedOperator`, every keeper preflight and post-simulation canonical-head check also rechecks the RPC quorum and compares its agreed hash against the caller-supplied signer verifier. A primary-only signer verifier cannot bypass a divergent witness. The existing recovery store, publication, and supervisor reject mismatches; HTTP and keeper admission stay closed after errors.

When running an approved rebuild, pass this wrapped adapter to `quarantineOrphanedRecovery`; the approval still names the exact rejected head and independently reviewed new canonical hash. A quorum cannot establish finality by itself. Different providers may share a faulty upstream, collude, be stale, or reorganize simultaneously. Keep the operational stop-the-world and archival procedures from `REBUILD.md`.

## Limitations

Only block headers are independently confirmed. Event decoding, mark prices, portfolio health, and auxiliary timestamps are read from the designated primary. This design is deliberately fail-closed on RPC timeouts and chain ID disagreements. The `required` threshold cannot be lower than two. Do not infer audited security or measured performance from this integration.

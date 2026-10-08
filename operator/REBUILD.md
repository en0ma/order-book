# Operator-approved recovery after a canonical reorg

A persisted Core index and strategy bundle can belong to an orphaned branch. The default recovery controller rejects this checkpoint and closes HTTP publication and keeper admission. Never silently delete the bundle or assume a new RPC result is canonical.

## Cold rebuild procedure

1. Stop the supervisor, keeper execution, HTTP server, and all processes that might write the recovery bundle.
2. Confirm the expected chain ID and canonical block hash using a trusted, independent RPC source.
3. Review the saved checkpoint number and hash and obtain explicit operator authorization to discard that **live checkpoint**.
4. Call `quarantineOrphanedRecovery` with the exact saved checkpoint number/hash and the approved canonical hash.
5. The helper validates the deployment identity and both Core and strategy payloads, rejects an already-canonical checkpoint, creates a unique hard-link archive, syncs its directory entry, verifies chain identity and canonical hash again, then unlinks and syncs the live bundle path.
6. **Create a new** self-hosted operator instance and run bounded `bootstrap`. Inspect recovered state and readiness before admitting HTTP/keeper activity.
7. Retain the archived file for incident analysis. Apply backup and deletion policies separately.

```js
import { quarantineOrphanedRecovery } from "@en0ma/order-book-operator/rebuild";
import { createSelfHostedOperator } from "@en0ma/order-book-operator/self-hosted";

// Stop all old processes before this operation.
const archived = await quarantineOrphanedRecovery(manifest, trustedRpc, bundlePath, {
  checkpointNumber: reviewedBlockNumber,
  checkpointHash: reviewedOldHash,
  canonicalHash: independentlyVerifiedCurrentHash,
});
console.log(archived.archivedPath);
const operator = createSelfHostedOperator(manifest, trustedRpc, { bundlePath });
await operator.bootstrap({ maxCycles: 100, listen: { port: 8080 } });
```

The archive is a hard link on the same filesystem. It is not an independent backup until copied elsewhere. The helper does not monitor background writers, guarantee finality, prove that the approved source is trustworthy, or solve reorgs after rebuilding. A failed recheck can leave an archived hard link while retaining the active checkpoint; inspect before retry. This operation is **not** an automatic reorg handler and must not be exposed to untrusted HTTP clients.

The operator repository remains unaudited and not production-ready.

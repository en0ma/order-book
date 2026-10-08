import { resolve } from "node:path";
import { JsonFileRecoveryStore, JsonlOperatorAuditJournal } from "./node.js";
import { createRecoveryPublication, type RecoveryPublication } from "./publication.js";
import { createHttpRuntime, type HttpRuntime, type HttpRuntimeOptions } from "./http.js";
import { operatorManifestIdentity, validateOperatorManifest, type OperatorRpcAdapter, type OperatorSyncOptions } from "./index.js";
import type { RecoveryCycleResult } from "./recovery-cycle.js";

/** A single-process self-hosted composition. RPC and auth stay with the operator. */
export interface SelfHostedOperator {
  publication: RecoveryPublication;
  http: HttpRuntime;
  recover(): Promise<RecoveryCycleResult>;
}
export interface SelfHostedOperatorOptions {
  bundlePath: string;
  auditPath?: string;
  sync?: OperatorSyncOptions;
  http?: Omit<HttpRuntimeOptions, "snapshot" | "markets" | "readiness">;
}

/** Do not bind the HTTP port until the operator explicitly calls http.listen(). */
export function createSelfHostedOperator(
  manifestInput: unknown, rpc: OperatorRpcAdapter, options: SelfHostedOperatorOptions,
): SelfHostedOperator {
  const manifest = validateOperatorManifest(manifestInput);
  if (options.auditPath && resolve(options.auditPath) === resolve(options.bundlePath)) {
    throw new TypeError("audit journal path must differ from recovery bundle path");
  }
  const store = new JsonFileRecoveryStore(options.bundlePath);
  const publication = createRecoveryPublication(manifest, rpc, store, options.sync);
  const journal = options.auditPath ? new JsonlOperatorAuditJournal(options.auditPath) : undefined;
  const http = createHttpRuntime({
    ...options.http,
    snapshot: () => publication.snapshot(),
    markets: manifest.markets.map(market => market.id),
    readiness: { requireDiagnostics: true, maxLagBlocks: 0 },
  });
  return {
    publication, http,
    async recover() {
      try {
        const result = await publication.refresh();
        await journal?.append({
          timestamp: new Date().toISOString(),
          manifestIdentity: operatorManifestIdentity(manifest),
          kind: "cycle",
          payload: { head: result.head, appliedBlocks: result.appliedBlocks,
            restored: result.restored, ready: result.readiness.ready },
        });
        return result;
      } catch (error) {
        // Audit is best effort; the publication controller has already closed the gate.
        try {
          await journal?.append({
            timestamp: new Date().toISOString(),
            manifestIdentity: operatorManifestIdentity(manifest),
            kind: "error",
            payload: { message: error instanceof Error ? error.message : "unknown error" },
          });
        } catch { /* Preserve the original recovery failure. */ }
        throw error;
      }
    },
  };
}

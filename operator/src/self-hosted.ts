import { resolve } from "node:path";
import { createOperatorSupervisor, type OperatorSupervisor, type SupervisorOptions } from "./supervisor.js";
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
  bootstrap(config?: BootstrapOptions): Promise<RecoveryCycleResult>;
  supervise(options?: SupervisorOptions): OperatorSupervisor;
}
export interface BootstrapOptions {
  maxCycles?: number;
  signal?: AbortSignal;
  listen?: { port: number; host?: string };
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
  let bootstrapping = false;
  async function recover(): Promise<RecoveryCycleResult> {
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
      try {
        await journal?.append({
          timestamp: new Date().toISOString(),
          manifestIdentity: operatorManifestIdentity(manifest),
          kind: "error",
          payload: { message: error instanceof Error ? error.message : "unknown error" },
        });
      } catch { /* Preserve the original recovery error. */ }
      throw error;
    }
  }
  return {
    publication, http, recover,
    supervise(options: SupervisorOptions = {}) {
      return createOperatorSupervisor({ ...publication, refresh: recover }, options);
    },
    async bootstrap(config: BootstrapOptions = {}) {
      if (bootstrapping) throw new Error("operator bootstrap already running");
      const maxCycles = config.maxCycles ?? 100;
      if (!Number.isSafeInteger(maxCycles) || maxCycles < 1 || maxCycles > 100_000) {
        throw new RangeError("invalid maximum bootstrap cycles");
      }
      bootstrapping = true;
      try {
        for (let cycle = 0; cycle < maxCycles; cycle++) {
          if (config.signal?.aborted) throw new Error("operator bootstrap aborted");
          const result = await recover();
          if (config.signal?.aborted) throw new Error("operator bootstrap aborted");
          if (result.readiness.ready && publication.ready()) {
            if (config.listen) await http.listen(config.listen.port, config.listen.host);
            return result;
          }
          if (result.appliedBlocks === 0) break;
        }
        throw new Error("operator bootstrap did not reach canonical readiness");
      } finally {
        bootstrapping = false;
      }
    },
  };
}

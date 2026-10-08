import type { OperatorRpcAdapter, OperatorSyncOptions } from "./index.js";
import type { HttpRuntime, HttpRuntimeOptions } from "./http.js";
import type { RecoveryPublication } from "./publication.js";
import type { OperatorSupervisor, SupervisorOptions } from "./supervisor.js";
import type { RecoveryCycleResult } from "./recovery-cycle.js";
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
export declare function createSelfHostedOperator(manifestInput: unknown,
  rpc: OperatorRpcAdapter, options: SelfHostedOperatorOptions): SelfHostedOperator;

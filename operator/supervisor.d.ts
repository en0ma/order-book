import type { RecoveryPublication } from "./publication.js";
import type { KeeperTask, IdempotentKeeperExecutor } from "./index.js";
import type { CanonicalHeadVerifier, KeeperAdmissionResult } from "./recovery.js";
export interface SupervisorOptions {
  intervalMs?: number;
  maxBackoffMs?: number;
  signal?: AbortSignal;
  onCycle?: (event: { kind: "ready" | "lagging" | "error"; attempt: number; head?: number; message?: string }) => void;
}
export interface OperatorSupervisor {
  run(): Promise<void>;
  stop(): void;
  submit(tasks: readonly KeeperTask[], executor: IdempotentKeeperExecutor,
    verifier: CanonicalHeadVerifier): Promise<KeeperAdmissionResult>;
  status(): { running: boolean; ready: boolean; failures: number; cycles: number };
}
export declare function createOperatorSupervisor(
  publication: RecoveryPublication, options?: SupervisorOptions,
): OperatorSupervisor;

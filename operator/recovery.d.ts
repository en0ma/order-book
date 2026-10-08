import type { IdempotentKeeperExecutor, KeeperTask, OperatorCheckpoint } from "./index.js";
import type { StrategySnapshot } from "./strategies.js";
import type { ReadinessPolicy } from "./readiness.js";
import type { ApiSnapshot, OperatorDiagnostics } from "./api.js";
export interface RecoveryBundle {
  version: 1; identity: string; checkpoint: OperatorCheckpoint; strategies: StrategySnapshot;
  strategyHead: { number: number; hash: string };
}
export interface RecoveryStore {
  load(identity: string): Promise<RecoveryBundle | undefined>;
  save(identity: string, bundle: RecoveryBundle): Promise<void>;
}
export declare function assembleRecoveryBundle(manifest: unknown, checkpoint: OperatorCheckpoint,
  strategies: StrategySnapshot, strategyHead: { number: number; hash: string }): RecoveryBundle;
export declare function validateRecoveryBundle(manifest: unknown, bundle: RecoveryBundle): void;
export interface KeeperAdmissionResult { admitted: number; skipped: number; transactionIds: string[]; }
export declare function executeReadyTasks(manifest: unknown, checkpoint: OperatorCheckpoint,
  snapshot: ApiSnapshot, diagnostics: OperatorDiagnostics, tasks: readonly KeeperTask[],
  executor: IdempotentKeeperExecutor, policy?: ReadinessPolicy): Promise<KeeperAdmissionResult>;

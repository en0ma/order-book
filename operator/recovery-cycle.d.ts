import type { OperatorRpcAdapter, OperatorSyncOptions } from "./index.js";
import type { RecoveryBundle, RecoveryStore } from "./recovery.js";
import type { ReadModel } from "./read-model.js";
import type { ReadinessResult } from "./readiness.js";
export interface RecoveryCycleResult {
  restored: boolean;
  remoteHead: number;
  safeHead: number;
  appliedBlocks: number;
  head: { number: number; hash: string };
  readiness: ReadinessResult;
  readModel: ReadModel;
  bundle: RecoveryBundle;
}
export declare function runRecoveryCycle(
  manifestInput: unknown, rpc: OperatorRpcAdapter, store: RecoveryStore,
  options?: OperatorSyncOptions,
): Promise<RecoveryCycleResult>;

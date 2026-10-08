import type { OperatorRpcAdapter, OperatorSyncOptions, KeeperTask, IdempotentKeeperExecutor } from "./index.js";
import type { RecoveryStore, CanonicalHeadVerifier, KeeperAdmissionResult } from "./recovery.js";
import type { RecoveryCycleResult } from "./recovery-cycle.js";
import type { ReadModel } from "./read-model.js";
export interface RecoveryPublication {
  ready(): boolean;
  snapshot(): ReadModel;
  refresh(): Promise<RecoveryCycleResult>;
  submit(tasks: readonly KeeperTask[], executor: IdempotentKeeperExecutor,
    verifier: CanonicalHeadVerifier): Promise<KeeperAdmissionResult>;
}
export declare function createRecoveryPublication(manifest: unknown, rpc: OperatorRpcAdapter,
  store: RecoveryStore, options?: OperatorSyncOptions): RecoveryPublication;

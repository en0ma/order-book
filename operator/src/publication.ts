import { runRecoveryCycle, type RecoveryCycleResult } from "./recovery-cycle.js";
import { executeReadyTasks, type KeeperAdmissionResult, type CanonicalHeadVerifier, type RecoveryStore } from "./recovery.js";
import type { OperatorRpcAdapter, OperatorSyncOptions, KeeperTask, IdempotentKeeperExecutor } from "./index.js";
import type { ReadModel } from "./read-model.js";

/** Self-hosted publication and admission boundary. Does not own a server or keys. */
export interface RecoveryPublication {
  /** True only after the last recovery cycle committed and reached the safe head. */
  ready(): boolean;
  /** HTTP snapshot callback. Never returns stale state after a failed refresh. */
  snapshot(): ReadModel;
  /** Serializes refresh attempts so an older replay cannot overwrite a newer commit. */
  refresh(): Promise<RecoveryCycleResult>;
  /** Requires a committed ready cycle and verifies the canonical hash before submission. */
  submit(tasks: readonly KeeperTask[], executor: IdempotentKeeperExecutor,
    verifier: CanonicalHeadVerifier): Promise<KeeperAdmissionResult>;
}

export function createRecoveryPublication(
  manifest: unknown, rpc: OperatorRpcAdapter, store: RecoveryStore,
  options: OperatorSyncOptions = {},
): RecoveryPublication {
  let published: RecoveryCycleResult | undefined;
  let gateOpen = false;
  let pendingRefreshes = 0;
  let tail: Promise<unknown> = Promise.resolve();
  function serialize<T>(work: () => Promise<T>): Promise<T> {
    const result = tail.then(work, work);
    tail = result.then(() => undefined, () => undefined);
    return result;
  }
  return {
    ready: () => gateOpen && pendingRefreshes === 0 && published?.readiness.ready === true,
    snapshot() {
      if (!gateOpen || pendingRefreshes !== 0 || !published?.readiness.ready) {
        throw new Error("canonical recovery is not ready for publication");
      }
      return published.readModel;
    },
    refresh() {
      // Fail closed before the first awaited RPC or storage operation.
      gateOpen = false;
      pendingRefreshes++;
      return serialize(async () => {
        try {
          const candidate = await runRecoveryCycle(manifest, rpc, store, options);
          published = candidate;
          gateOpen = candidate.readiness.ready && pendingRefreshes === 1;
          return candidate;
        } catch (error) {
          published = undefined;
          gateOpen = false;
          throw error;
        } finally {
          pendingRefreshes--;
        }
      });
    },
    submit(tasks, executor, verifier) {
      return serialize(async () => {
        if (!gateOpen || pendingRefreshes !== 0 || !published?.readiness.ready ||
            !published.readModel.diagnostics) {
          throw new Error("keeper submission rejected: recovery is not ready");
        }
        const candidate = published;
        return executeReadyTasks(
          manifest, candidate.bundle.checkpoint, candidate.readModel.snapshot,
          candidate.readModel.diagnostics, tasks, executor, verifier,
        );
      });
    },
  };
}

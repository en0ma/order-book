import {
  keeperTaskId, operatorManifestIdentity, type IdempotentKeeperExecutor,
  type KeeperTask, type OperatorCheckpoint,
} from "./index.js";
import type { StrategySnapshot, StrategyTask } from "./strategies.js";
import { checkReadiness, type ReadinessPolicy } from "./readiness.js";
import type { ApiSnapshot, OperatorDiagnostics } from "./api.js";

export interface RecoveryBundle {
  version: 1;
  identity: string;
  checkpoint: OperatorCheckpoint;
  strategies: StrategySnapshot;
  strategyHead: { number: number; hash: string };
}
export interface RecoveryStore {
  load(identity: string): Promise<RecoveryBundle | undefined>;
  save(identity: string, bundle: RecoveryBundle): Promise<void>;
}
export function assembleRecoveryBundle(
  manifest: unknown, checkpoint: OperatorCheckpoint, strategies: StrategySnapshot,
  strategyHead: { number: number; hash: string },
): RecoveryBundle {
  const identity = operatorManifestIdentity(manifest);
  if (checkpoint.manifestIdentity !== identity || checkpoint.version !== 1
    || !checkpoint.head || checkpoint.head.number !== strategyHead.number
    || checkpoint.head.hash !== strategyHead.hash || strategies.version !== 1) {
    throw new Error("index and strategy recovery heads do not match");
  }
  return { version: 1, identity, checkpoint, strategies, strategyHead: { ...strategyHead } };
}
export function validateRecoveryBundle(manifest: unknown, bundle: RecoveryBundle): void {
  if (!bundle || bundle.version !== 1 ||
    bundle.identity !== operatorManifestIdentity(manifest)) {
    throw new Error("recovery bundle deployment identity mismatch");
  }
  assembleRecoveryBundle(manifest, bundle.checkpoint, bundle.strategies, bundle.strategyHead);
}
export type AdmittedTask = KeeperTask | StrategyTask;
export interface KeeperAdmissionResult {
  admitted: number;
  skipped: number;
  transactionIds: string[];
}
/** Fail closed when the indexed head differs from the current safe-head diagnostics. */
export async function executeReadyTasks(
  manifest: unknown,
  checkpoint: OperatorCheckpoint,
  snapshot: ApiSnapshot,
  diagnostics: OperatorDiagnostics,
  tasks: readonly KeeperTask[],
  executor: IdempotentKeeperExecutor,
  policy: ReadinessPolicy = { requireDiagnostics: true, maxLagBlocks: 0 },
): Promise<KeeperAdmissionResult> {
  const readiness = checkReadiness(snapshot, diagnostics, policy);
  if (!readiness.ready || !checkpoint.head || !snapshot.head ||
    checkpoint.manifestIdentity !== operatorManifestIdentity(manifest) ||
    checkpoint.head.number !== snapshot.head.number ||
    checkpoint.head.hash !== snapshot.head.hash) {
    throw new Error("keeper submission rejected: canonical state is not ready");
  }
  const branchEpoch = checkpoint.branchEpoch ?? 0;
  let skipped = 0;
  const transactionIds: string[] = [];
  for (const task of tasks) {
    const key = keeperTaskId(manifest, branchEpoch, task);
    if (await executor.alreadySubmitted(key) || !await executor.simulate(task)) {
      skipped++;
      continue;
    }
    // Confirm readiness again after simulation, before transaction submission.
    // The caller must still recheck chain state in its signing/relay adapter.
    transactionIds.push(await executor.submit(task, key));
  }
  return { admitted: transactionIds.length, skipped, transactionIds };
}

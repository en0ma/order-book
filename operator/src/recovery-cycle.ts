import {
  ReferenceIndexer, operatorManifestIdentity, validateOperatorManifest,
  type OperatorRpcAdapter, type OperatorSyncOptions,
} from "./index.js";
import { StrategyRegistry } from "./strategies.js";
import {
  assembleRecoveryBundle, validateRecoveryBundle,
  type RecoveryBundle, type RecoveryStore,
} from "./recovery.js";
import { buildApiSnapshot, type ApiSnapshot, type OperatorDiagnostics } from "./api.js";
import { composeReadModel, type ReadModel } from "./read-model.js";
import { checkReadiness, type ReadinessResult } from "./readiness.js";

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

/**
 * Replay both protocol state machines from one trusted checkpoint.
 * Do not change the caller's published read model unless this function succeeds.
 */
export async function runRecoveryCycle(
  manifestInput: unknown,
  rpc: OperatorRpcAdapter,
  store: RecoveryStore,
  options: OperatorSyncOptions = {},
): Promise<RecoveryCycleResult> {
  const manifest = validateOperatorManifest(manifestInput);
  if (await rpc.getChainId() !== manifest.chainId) {
    throw new Error("recovery RPC chain ID does not match manifest");
  }
  const confirmationDepth = options.confirmationDepth ?? 0;
  const maxBlocksPerSync = options.maxBlocksPerSync ?? 128;
  if (!Number.isSafeInteger(confirmationDepth) || confirmationDepth < 0 ||
      !Number.isSafeInteger(maxBlocksPerSync) || maxBlocksPerSync < 1 || maxBlocksPerSync > 10_000) {
    throw new RangeError("invalid recovery sync options");
  }
  const remoteHead = await rpc.getHeadBlockNumber();
  const safeHead = remoteHead - confirmationDepth;
  const identity = operatorManifestIdentity(manifest);
  const loaded = await store.load(identity);
  const indexer = new ReferenceIndexer(manifest.chainId);
  const registry = new StrategyRegistry();
  if (loaded) {
    validateRecoveryBundle(manifest, loaded);
    indexer.restoreCheckpoint(loaded.checkpoint, manifest);
    registry.restore(loaded.strategies);
    const saved = indexer.headBlock()!;
    if (saved.number > safeHead) throw new Error("checkpoint is ahead of safe head");
    if ((await rpc.getBlock(saved.number)).hash !== saved.hash) {
      throw new Error("stored checkpoint is not on the canonical branch; operator rebuild is required");
    }
  }
  const first = (indexer.headBlock()?.number ?? (manifest.deploymentBlock - 1)) + 1;
  const last = Math.min(safeHead, first + maxBlocksPerSync - 1);
  let appliedBlocks = 0;
  for (let number = first; number <= last; number++) {
    const block = await rpc.getBlock(number);
    const events = await rpc.getEvents(block, manifest);
    indexer.applyBlock(block, events);
    registry.applyBatch(events);
    appliedBlocks++;
  }
  const head = indexer.headBlock();
  if (!head) throw new Error("no canonical block available for recovery");
  // Guard against reorgs during replay. This cannot prevent reorgs after commit.
  if ((await rpc.getBlock(head.number)).hash !== head.hash) {
    throw new Error("canonical head changed during recovery; do not publish state");
  }
  const bundle = assembleRecoveryBundle(
    manifest, indexer.checkpoint(manifest), registry.snapshot(),
    { number: head.number, hash: head.hash },
  );
  validateRecoveryBundle(manifest, bundle);
  const snapshot: ApiSnapshot = buildApiSnapshot(manifest, indexer);
  const lagBlocks = Math.max(0, safeHead - head.number);
  const diagnostics: OperatorDiagnostics = {
    status: lagBlocks === 0 ? "healthy" : appliedBlocks > 0 ? "catching_up" : "stalled",
    headBlock: head.number, remoteHead, safeHead,
    lagBlocks, appliedBlocks, taskCounts: {}, activeConditionals: 0,
    activeTrailing: 0, managedQuotes: 0, portfolioAccounts: 0,
  };
  const readiness = checkReadiness(snapshot, diagnostics);
  // The store must commit the complete bundle in one atomic write.
  // The caller promotes the returned read model only after this write resolves.
  await store.save(identity, bundle);
  return {
    restored: Boolean(loaded), remoteHead, safeHead, appliedBlocks,
    head: { number: head.number, hash: head.hash }, readiness,
    bundle, readModel: composeReadModel(snapshot, bundle.strategies, diagnostics),
  };
}

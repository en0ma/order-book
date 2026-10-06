import type {
  IndexState,
  KeeperTask,
  OperatorManifest,
  OperatorSyncResult,
  ReferenceIndexer,
} from "./index.js";

export interface OperatorDiagnostics {
  status: "healthy" | "catching_up" | "stalled";
  headBlock?: number;
  remoteHead: number;
  safeHead: number;
  lagBlocks: number;
  appliedBlocks: number;
  rolledBackTo?: number;
  taskCounts: Record<string, number>;
  activeConditionals: number;
  activeTrailing: number;
  managedQuotes: number;
  portfolioAccounts: number;
}

export interface ApiSnapshot {
  version: 1;
  chainId: number;
  head?: { number: number; hash: string };
  pools: { key: string; remainingLots: string; generation: number }[];
  conditionals: { key: string; active: boolean; dormant: boolean; expiry: string; resting: boolean }[];
  trailing: { key: string; active: boolean; expiry: string }[];
  managedQuotes: { key: string; shares: string; generation: number }[];
  portfolioLocks: { account: string; equity: string; requirement: string; lockedCollateral: string }[];
}

export interface OperatorStreamEnvelope {
  type: "snapshot" | "diagnostics" | "tasks";
  chainId: number;
  headBlock?: number;
  payload: ApiSnapshot | OperatorDiagnostics | { tasks: ReturnType<typeof serializeKeeperTask>[] };
}

export function serializeKeeperTask(task: KeeperTask): Record<string, unknown> {
  if (task.kind === "liquidationCandidate") {
    return {
      ...task,
      conditionalIds: task.conditionalIds.map(String),
      trailingIds: task.trailingIds.map(String),
    };
  }
  return { ...task, orderId: task.orderId.toString() };
}

export function buildApiSnapshot(
  manifest: OperatorManifest,
  indexer: ReferenceIndexer,
): ApiSnapshot {
  const state = indexer.state;
  const head = indexer.headBlock();
  return {
    version: 1,
    chainId: manifest.chainId,
    ...(head ? { head: { number: head.number, hash: head.hash } } : {}),
    pools: [...state.pools].sort().map(([key, value]) => ({
      key,
      remainingLots: value.remainingLots.toString(),
      generation: value.generation,
    })),
    conditionals: [...state.conditionals].sort().map(([key, value]) => ({
      key,
      active: value.active,
      dormant: Boolean(value.dormant),
      expiry: value.expiry.toString(),
      resting: value.resting,
    })),
    trailing: [...state.trailing].sort().map(([key, value]) => ({
      key,
      active: value.active,
      expiry: value.expiry.toString(),
    })),
    managedQuotes: [...state.managedQuotes].sort().map(([key, value]) => ({
      key,
      shares: value.shares.toString(),
      generation: value.generation,
    })),
    portfolioLocks: [...state.portfolioLocks].sort().map(([account, value]) => ({
      account,
      equity: value.equity.toString(),
      requirement: value.requirement.toString(),
      lockedCollateral: value.lockedCollateral.toString(),
    })),
  };
}

export function buildOperatorDiagnostics(
  indexer: ReferenceIndexer,
  sync: OperatorSyncResult,
): OperatorDiagnostics {
  const taskCounts: Record<string, number> = {};
  for (const task of sync.tasks) taskCounts[task.kind] = (taskCounts[task.kind] ?? 0) + 1;
  const lagBlocks = Math.max(0, sync.safeHead - (indexer.headBlock()?.number ?? sync.fromBlock - 1));
  return {
    status: lagBlocks === 0 ? "healthy" : sync.appliedBlocks > 0 ? "catching_up" : "stalled",
    headBlock: indexer.headBlock()?.number,
    remoteHead: sync.remoteHead,
    safeHead: sync.safeHead,
    lagBlocks,
    appliedBlocks: sync.appliedBlocks,
    ...(sync.rolledBackTo !== undefined ? { rolledBackTo: sync.rolledBackTo } : {}),
    taskCounts,
    activeConditionals: [...indexer.state.conditionals.values()].filter((v) => v.active || v.resting).length,
    activeTrailing: [...indexer.state.trailing.values()].filter((v) => v.active).length,
    managedQuotes: indexer.state.managedQuotes.size,
    portfolioAccounts: indexer.state.portfolioLocks.size,
  };
}

export function snapshotEnvelope(
  manifest: OperatorManifest,
  indexer: ReferenceIndexer,
): OperatorStreamEnvelope {
  return {
    type: "snapshot",
    chainId: manifest.chainId,
    headBlock: indexer.headBlock()?.number,
    payload: buildApiSnapshot(manifest, indexer),
  };
}

export function diagnosticsEnvelope(
  manifest: OperatorManifest,
  indexer: ReferenceIndexer,
  sync: OperatorSyncResult,
): OperatorStreamEnvelope {
  return {
    type: "diagnostics",
    chainId: manifest.chainId,
    headBlock: indexer.headBlock()?.number,
    payload: buildOperatorDiagnostics(indexer, sync),
  };
}

export function tasksEnvelope(
  manifest: OperatorManifest,
  indexer: ReferenceIndexer,
  tasks: readonly KeeperTask[],
): OperatorStreamEnvelope {
  return {
    type: "tasks",
    chainId: manifest.chainId,
    headBlock: indexer.headBlock()?.number,
    payload: { tasks: tasks.map(serializeKeeperTask) },
  };
}

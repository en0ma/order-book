import type { KeeperTask, OperatorManifest, OperatorSyncResult, ReferenceIndexer } from "./index.js";
export interface OperatorDiagnostics {
  status: "healthy" | "catching_up" | "stalled";
  headBlock?: number; remoteHead: number; safeHead: number; lagBlocks: number; appliedBlocks: number; rolledBackTo?: number;
  taskCounts: Record<string, number>; activeConditionals: number; activeTrailing: number; managedQuotes: number; portfolioAccounts: number;
}
export interface ApiSnapshot {
  version: 1; chainId: number; head?: { number: number; hash: string };
  pools: { key: string; remainingLots: string; generation: number }[];
  conditionals: { key: string; active: boolean; dormant: boolean; expiry: string; resting: boolean }[];
  trailing: { key: string; active: boolean; expiry: string }[];
  managedQuotes: { key: string; shares: string; generation: number }[];
  portfolioLocks: { account: string; equity: string; requirement: string; lockedCollateral: string }[];
}
export interface OperatorStreamEnvelope {
  type: "snapshot" | "diagnostics" | "tasks"; chainId: number; headBlock?: number;
  payload: ApiSnapshot | OperatorDiagnostics | { tasks: Record<string, unknown>[] };
}
export declare function serializeKeeperTask(task: KeeperTask): Record<string, unknown>;
export declare function buildApiSnapshot(manifest: OperatorManifest, indexer: ReferenceIndexer): ApiSnapshot;
export declare function buildOperatorDiagnostics(indexer: ReferenceIndexer, sync: OperatorSyncResult): OperatorDiagnostics;
export declare function snapshotEnvelope(manifest: OperatorManifest, indexer: ReferenceIndexer): OperatorStreamEnvelope;
export declare function diagnosticsEnvelope(manifest: OperatorManifest, indexer: ReferenceIndexer, sync: OperatorSyncResult): OperatorStreamEnvelope;
export declare function tasksEnvelope(manifest: OperatorManifest, indexer: ReferenceIndexer, tasks: readonly KeeperTask[]): OperatorStreamEnvelope;

import type { OperatorRpcAdapter } from "./index.js";
export interface RebuildApproval {
  checkpointNumber: number;
  checkpointHash: string;
  canonicalHash: string;
}
export interface RebuildPreparation {
  archivedPath: string;
  rejectedHead: { number: number; hash: string };
  observedCanonicalHash: string;
}
export declare function quarantineOrphanedRecovery(
  manifestInput: unknown, rpc: OperatorRpcAdapter, bundlePath: string,
  approval: RebuildApproval,
): Promise<RebuildPreparation>;

import type { BlockRef, NormalizedEvent } from "./index.js";
export interface ClaimantHistoryBlock {
  block: BlockRef;
  events: readonly NormalizedEvent[];
}
export interface ClaimantInventory {
  chainId: number;
  deploymentBlock: number;
  blockNumber: number;
  blockHash: string;
  accounts: readonly string[];
  eventCount: number;
}
/** Diagnostic only. Caller must prove complete ABI and finalized history coverage. */
export declare function replayClaimantInventory(
  chainId: number,
  deploymentBlock: number,
  history: readonly ClaimantHistoryBlock[],
): ClaimantInventory;

export interface ClaimantHistoryReader {
  getChainId(): Promise<number>;
  getBlock(blockNumber: number): Promise<BlockRef>;
  getEvents(block: BlockRef): Promise<readonly NormalizedEvent[]>;
}
export interface FinalizedClaimantAnchor {
  chainId: number;
  blockNumber: number;
  blockHash: string;
}
/** Diagnostic only. The anchor and complete RPC logs must be independently authenticated. */
export declare function discoverClaimantsAtAnchor(
  reader: ClaimantHistoryReader,
  deploymentBlock: number,
  anchor: FinalizedClaimantAnchor,
): Promise<ClaimantInventory>;

/** Diagnostic only: trustedContracts require independently verified provenance. */
export declare function replayClaimantInventoryForDeployment(
  chainId: number, deploymentBlock: number,
  history: readonly ClaimantHistoryBlock[],
  trustedContracts: readonly string[],
): ClaimantInventory;

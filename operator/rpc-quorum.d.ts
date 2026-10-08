import type { BlockRef, OperatorRpcAdapter } from "./index.js";
export interface QuorumRpcOptions { required?: number }
export interface QuorumRpcAdapter extends OperatorRpcAdapter {
  verifyBlock(blockNumber: number): Promise<BlockRef>;
}
export declare function createQuorumRpcAdapter(
  primary: OperatorRpcAdapter, witnesses: readonly OperatorRpcAdapter[],
  options?: QuorumRpcOptions,
): QuorumRpcAdapter;

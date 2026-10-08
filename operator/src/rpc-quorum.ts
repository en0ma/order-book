import type { Address, BlockRef, NormalizedEvent, OperatorManifest, OperatorRpcAdapter } from "./index.js";

export interface QuorumRpcOptions {
  /** Minimum agreeing RPC endpoints, including the primary; defaults to every configured endpoint. */
  required?: number;
}
export interface QuorumRpcAdapter extends OperatorRpcAdapter {
  /** Verify a specific canonical block with all configured sources before any recovery use. */
  verifyBlock(blockNumber: number): Promise<BlockRef>;
}

function sameBlock(a: BlockRef, b: BlockRef): boolean {
  return a.number === b.number && a.hash.toLowerCase() === b.hash.toLowerCase()
    && a.parentHash.toLowerCase() === b.parentHash.toLowerCase();
}

/** Conservative RPC consensus boundary for canonical recovery and supervised publication.
 * Does not silently replace the primary source or accept failures as agreement.
 */
export function createQuorumRpcAdapter(
  primary: OperatorRpcAdapter, witnesses: readonly OperatorRpcAdapter[],
  options: QuorumRpcOptions = {},
): QuorumRpcAdapter {
  if (!primary || typeof primary.getBlock !== "function" ||
      !Array.isArray(witnesses) || witnesses.length === 0 ||
      witnesses.some(rpc => !rpc || typeof rpc.getBlock !== "function" ||
        typeof rpc.getChainId !== "function" || typeof rpc.getHeadBlockNumber !== "function")) {
    throw new TypeError("primary RPC and at least one independent witness are required");
  }
  const sources = [primary, ...witnesses];
  const required = options.required ?? sources.length;
  if (!Number.isSafeInteger(required) || required < 2 || required > sources.length) {
    throw new RangeError("invalid canonical RPC quorum");
  }
  async function chainId(): Promise<number> {
    // A chain identity mismatch is never safe to ignore, even if other providers agree.
    const values = await Promise.all(sources.map(rpc => rpc.getChainId()));
    if (values.some(value => value !== values[0])) throw new Error("canonical RPC chain identity disagreement");
    return values[0];
  }
  async function heads(): Promise<number[]> {
    await chainId();
    const values = await Promise.all(sources.map(rpc => rpc.getHeadBlockNumber()));
    if (values.some(value => !Number.isSafeInteger(value) || value < 0)) {
      throw new Error("invalid canonical RPC head");
    }
    return values;
  }
  async function verifyBlock(blockNumber: number): Promise<BlockRef> {
    if (!Number.isSafeInteger(blockNumber) || blockNumber < 0) {
      throw new RangeError("invalid canonical block height");
    }
    const values = await heads();
    if (values[0] < blockNumber) throw new Error("primary RPC is behind canonical block height");
    const eligible = sources.filter((_, i) => values[i] >= blockNumber);
    if (eligible.length < required) throw new Error("not enough canonical RPC sources at block height");
    const blocks = await Promise.all(eligible.map(rpc => rpc.getBlock(blockNumber)));
    const primaryBlock = blocks[0];
    if (!primaryBlock || primaryBlock.number !== blockNumber ||
        typeof primaryBlock.hash !== "string" || typeof primaryBlock.parentHash !== "string") {
      throw new Error("invalid primary canonical block");
    }
    const votes = blocks.filter(block => block && sameBlock(primaryBlock, block)).length;
    if (votes < required) throw new Error("canonical RPC block hash disagreement");
    return primaryBlock;
  }
  return {
    getChainId: chainId,
    // Use the required-th highest height: at least 'required' RPCs reached it.
    async getHeadBlockNumber() {
      const values = await heads();
      return [...values].sort((a, b) => b - a)[required - 1];
    },
    getBlock: verifyBlock,
    verifyBlock,
    async getEvents(block: BlockRef, manifest: OperatorManifest): Promise<readonly NormalizedEvent[]> {
      const canonical = await verifyBlock(block.number);
      if (!sameBlock(block, canonical)) throw new Error("requested block differs from RPC quorum");
      const events = await primary.getEvents(block, manifest);
      const after = await verifyBlock(block.number);
      if (!sameBlock(block, after)) throw new Error("canonical RPC block changed during event replay");
      return events;
    },
    getMarkTicks: manifest => primary.getMarkTicks(manifest),
    ...(primary.getPortfolioHealth ? {
      getPortfolioHealth: (accounts: readonly Address[], manifest: OperatorManifest) =>
        primary.getPortfolioHealth!(accounts, manifest),
    } : {}),
    ...(primary.getTimestamp ? { getTimestamp: () => primary.getTimestamp!() } : {}),
  };
}

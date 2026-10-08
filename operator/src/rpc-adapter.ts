import { normalizeCanonicalEvents, type CanonicalLogEnvelope } from "./integration.js";
import type { Address, BlockRef, NormalizedEvent, OperatorManifest, OperatorRpcAdapter } from "./index.js";

export interface JsonRpcTransport {
  request(method: string, params: readonly unknown[]): Promise<unknown>;
}
export interface RpcLog {
  address: Address;
  blockHash: string;
  blockNumber: string;
  transactionIndex: string;
  logIndex: string;
  topics: string[];
  data: string;
  removed?: boolean;
}
export interface CanonicalRpcOptions {
  /** Decode logs using the deployment ABI. Unknown topics must be explicitly ignored. */
  decode(log: RpcLog, chainId: number): CanonicalLogEnvelope | undefined;
  /** Required for mark-price reads; do not infer a price from old events. */
  markTicks?(manifest: OperatorManifest): Promise<Readonly<Record<string, number>>>;
}
const hex = (n: number) => "0x" + n.toString(16);
function quantity(value: unknown, name: string): number {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]+$/.test(value)) {
    throw new Error("invalid RPC " + name);
  }
  const n = Number(BigInt(value));
  if (!Number.isSafeInteger(n) || n < 0) throw new Error("unsafe RPC " + name);
  return n;
}
function hash(value: unknown, name: string): string {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error("invalid RPC " + name);
  }
  return value.toLowerCase();
}
function address(value: unknown): Address {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new Error("invalid RPC log address");
  }
  return value.toLowerCase() as Address;
}
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid RPC object");
  }
  return value as Record<string, unknown>;
}

/** Chain-linked JSON-RPC adapter. A deployment-specific ABI decoder is mandatory. */
export function createCanonicalRpcAdapter(
  transport: JsonRpcTransport, options: CanonicalRpcOptions,
): OperatorRpcAdapter {
  if (typeof transport?.request !== "function" || typeof options?.decode !== "function") {
    throw new TypeError("RPC transport and ABI decoder are required");
  }
  async function getChainId(): Promise<number> {
    return quantity(await transport.request("eth_chainId", []), "chain ID");
  }
  async function getBlock(number: number): Promise<BlockRef> {
    if (!Number.isSafeInteger(number) || number < 0) throw new RangeError("invalid block number");
    const block = record(await transport.request("eth_getBlockByNumber", [hex(number), false]));
    const found = quantity(block.number, "block number");
    if (found !== number) throw new Error("RPC returned wrong block number");
    return { number, hash: hash(block.hash, "block hash"),
      parentHash: hash(block.parentHash, "parent hash") };
  }
  return {
    getChainId,
    getHeadBlockNumber: async () => quantity(await transport.request("eth_blockNumber", []), "head"),
    getBlock,
    async getEvents(block, manifest): Promise<readonly NormalizedEvent[]> {
      const chainId = await getChainId();
      if (chainId !== manifest.chainId) throw new Error("RPC chain identity changed");
      const addresses = [...new Set(manifest.markets.flatMap(m =>
        [m.core, m.advanced, m.executionStrategy, m.marketMaker].filter((v): v is Address => Boolean(v))
      ).concat(manifest.portfolio ? [manifest.portfolio.coordinator] : []))];
      const raw = await transport.request("eth_getLogs", [{
        fromBlock: hex(block.number), toBlock: hex(block.number), address: addresses,
      }]);
      if (!Array.isArray(raw)) throw new Error("invalid RPC log list");
      const envelopes: CanonicalLogEnvelope[] = [];
      for (const value of raw) {
        const item = record(value);
        if (item.removed === true) throw new Error("RPC returned removed log");
        if (hash(item.blockHash, "log block hash") !== block.hash ||
            quantity(item.blockNumber, "log block number") !== block.number) {
          throw new Error("RPC log does not match requested canonical block");
        }
        const log: RpcLog = {
          address: address(item.address), blockHash: block.hash,
          blockNumber: item.blockNumber as string,
          transactionIndex: item.transactionIndex as string, logIndex: item.logIndex as string,
          topics: item.topics as string[], data: item.data as string,
        };
        if (!Array.isArray(log.topics) || log.topics.some(v => typeof v !== "string" || !/^0x[0-9a-fA-F]*$/.test(v)) ||
            typeof log.data !== "string" || !/^0x[0-9a-fA-F]*$/.test(log.data)) {
          throw new Error("invalid RPC log payload");
        }
        const decoded = options.decode(log, chainId);
        if (!decoded) continue;
        if (decoded.blockHash.toLowerCase() !== block.hash || decoded.blockNumber !== block.number ||
            decoded.chainId !== chainId ||
            decoded.address.toLowerCase() !== log.address.toLowerCase() ||
            decoded.transactionIndex !== quantity(item.transactionIndex, "transaction index") ||
            decoded.logIndex !== quantity(item.logIndex, "log index")) {
          throw new Error("decoded event envelope does not match RPC log");
        }
        envelopes.push(decoded);
      }
      // The block hash can change while logs are fetched. Refuse to publish that branch.
      if ((await getBlock(block.number)).hash !== block.hash) {
        throw new Error("canonical block changed during log retrieval");
      }
      envelopes.sort((a, b) => a.transactionIndex - b.transactionIndex || a.logIndex - b.logIndex);
      return normalizeCanonicalEvents(manifest, envelopes);
    },
    async getMarkTicks(manifest) {
      if (!options.markTicks) throw new Error("mark tick reader is not configured");
      return options.markTicks(manifest);
    },
  };
}

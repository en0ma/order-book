import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

import { decodeProtocolLog } from "./abi.js";

import {
  IndexerError,
  ReferenceIndexer,
  type Address,
  type BlockCursor,
  type DecodedProtocolEvent,
  type DeploymentManifest,
  type IndexedBlock,
  type IndexerCheckpoint,
  type ProtocolLog,
} from "./index.js";

export type Hex = `0x${string}`;

export interface RawRpcLog {
  address: Address;
  blockNumber: Hex;
  blockHash: string;
  transactionIndex: Hex;
  logIndex: Hex;
  topics: readonly Hex[];
  data: Hex;
}

export interface RpcBlockHeader {
  number: Hex;
  hash: string;
  parentHash: string;
}

export type ProtocolLogDecoder = (
  log: RawRpcLog,
  manifest: DeploymentManifest,
) => DecodedProtocolEvent | undefined;

export interface FetchLike {
  (
    input: string,
    init?: {
      method?: string;
      headers?: Record<string, string>;
      body?: string;
      signal?: AbortSignal;
    },
  ): Promise<{
    ok: boolean;
    status: number;
    text(): Promise<string>;
  }>;
}

interface JsonRpcEnvelope<T> {
  jsonrpc: "2.0";
  id: number;
  result?: T;
  error?: { code: number; message: string; data?: unknown };
}

function fromHex(value: Hex, field: string): number {
  const parsed = Number.parseInt(value.slice(2), 16);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new IndexerError(`${field} is not a safe hex integer`);
  }
  return parsed;
}

function toHex(value: number): Hex {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError("block number must be a non-negative safe integer");
  }
  return `0x${value.toString(16)}`;
}

function deploymentEventAddresses(manifest: DeploymentManifest): Address[] {
  const values = new Set<string>();
  const addresses: Address[] = [];

  const add = (address: Address | undefined) => {
    if (!address) return;
    const key = address.toLowerCase();
    if (values.has(key)) return;
    values.add(key);
    addresses.push(address);
  };

  for (const market of manifest.markets) {
    add(market.core);
    add(market.advanced);
    add(market.marketMaker);
  }
  add(manifest.portfolio?.coordinator);

  return addresses;
}

export class HttpJsonRpcClient {
  readonly url: string;
  readonly timeoutMs: number;

  private readonly fetchFn: FetchLike;
  private nextId = 1;

  constructor(
    url: string,
    options: { timeoutMs?: number; fetch?: FetchLike } = {},
  ) {
    if (!/^https?:\/\//.test(url)) throw new TypeError("RPC URL must be http(s)");
    this.url = url;
    this.timeoutMs = options.timeoutMs ?? 15_000;
    if (!Number.isSafeInteger(this.timeoutMs) || this.timeoutMs <= 0) {
      throw new RangeError("timeoutMs must be a positive safe integer");
    }

    const fallback = globalThis.fetch as unknown as FetchLike | undefined;
    this.fetchFn = options.fetch ?? fallback!;
    if (!this.fetchFn) throw new Error("fetch is unavailable");
  }

  async request<T>(method: string, params: readonly unknown[]): Promise<T> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const response = await this.fetchFn(this.url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: this.nextId++,
          method,
          params,
        }),
        signal: controller.signal,
      });
      const body = await response.text();
      if (!response.ok) {
        throw new Error(`RPC HTTP ${response.status}: ${body.slice(0, 256)}`);
      }

      let decoded: JsonRpcEnvelope<T>;
      try {
        decoded = JSON.parse(body) as JsonRpcEnvelope<T>;
      } catch {
        throw new Error("RPC returned invalid JSON");
      }

      if (decoded.error) {
        throw new Error(
          `RPC ${method} failed (${decoded.error.code}): ${decoded.error.message}`,
        );
      }
      if (!("result" in decoded)) throw new Error(`RPC ${method} omitted result`);
      return decoded.result as T;
    } finally {
      clearTimeout(timeout);
    }
  }

  async chainId(): Promise<number> {
    return fromHex(await this.request<Hex>("eth_chainId", []), "chainId");
  }

  async blockNumber(): Promise<number> {
    return fromHex(await this.request<Hex>("eth_blockNumber", []), "blockNumber");
  }

  async blockHeader(blockNumber: number): Promise<RpcBlockHeader> {
    const block = await this.request<RpcBlockHeader | null>(
      "eth_getBlockByNumber",
      [toHex(blockNumber), false],
    );
    if (!block?.hash || !block.parentHash) {
      throw new Error(`block ${blockNumber} is unavailable`);
    }
    return block;
  }

  async logs(blockNumber: number, addresses: readonly Address[]): Promise<RawRpcLog[]> {
    if (addresses.length === 0) return [];
    return this.request<RawRpcLog[]>("eth_getLogs", [
      {
        fromBlock: toHex(blockNumber),
        toBlock: toHex(blockNumber),
        address: addresses,
      },
    ]);
  }
}

export class JsonFileCheckpointStore {
  readonly path: string;

  constructor(path: string) {
    if (!path) throw new TypeError("checkpoint path is required");
    this.path = path;
  }

  async load(): Promise<IndexerCheckpoint | undefined> {
    try {
      return JSON.parse(await readFile(this.path, "utf8")) as IndexerCheckpoint;
    } catch (error) {
      const code = (error as { code?: string }).code;
      if (code === "ENOENT") return undefined;
      throw error;
    }
  }

  async save(checkpoint: IndexerCheckpoint): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const temporary = `${this.path}.tmp`;
    await writeFile(temporary, JSON.stringify(checkpoint, null, 2) + "\n", "utf8");
    await rename(temporary, this.path);
  }
}

export interface ReferenceNodeServiceOptions {
  maxReorgDepth?: number;
  persistEveryBlocks?: number;
}

export class ReferenceNodeService {
  readonly manifest: DeploymentManifest;
  readonly rpc: HttpJsonRpcClient;
  readonly decoder: ProtocolLogDecoder;
  readonly checkpointStore: JsonFileCheckpointStore;
  readonly indexer: ReferenceIndexer;

  private readonly addresses: Address[];
  private readonly persistEveryBlocks: number;

  private constructor(
    manifest: DeploymentManifest,
    rpc: HttpJsonRpcClient,
    decoder: ProtocolLogDecoder,
    checkpointStore: JsonFileCheckpointStore,
    checkpoint: IndexerCheckpoint | undefined,
    options: ReferenceNodeServiceOptions,
  ) {
    this.manifest = manifest;
    this.rpc = rpc;
    this.decoder = decoder;
    this.checkpointStore = checkpointStore;
    this.addresses = deploymentEventAddresses(manifest);
    this.persistEveryBlocks = options.persistEveryBlocks ?? 1;
    if (
      !Number.isSafeInteger(this.persistEveryBlocks)
      || this.persistEveryBlocks < 1
    ) {
      throw new RangeError("persistEveryBlocks must be a positive safe integer");
    }

    this.indexer = new ReferenceIndexer(manifest, {
      checkpoint,
      maxReorgDepth: options.maxReorgDepth,
    });
  }

  static async createCanonical(
    manifest: DeploymentManifest,
    rpc: HttpJsonRpcClient,
    checkpointStore: JsonFileCheckpointStore,
    options: ReferenceNodeServiceOptions = {},
  ): Promise<ReferenceNodeService> {
    return ReferenceNodeService.create(
      manifest,
      rpc,
      decodeProtocolLog,
      checkpointStore,
      options,
    );
  }

  static async create(
    manifest: DeploymentManifest,
    rpc: HttpJsonRpcClient,
    decoder: ProtocolLogDecoder,
    checkpointStore: JsonFileCheckpointStore,
    options: ReferenceNodeServiceOptions = {},
  ): Promise<ReferenceNodeService> {
    const chainId = await rpc.chainId();
    if (chainId !== manifest.chainId) {
      throw new Error(
        `RPC chainId ${chainId} does not match manifest chainId ${manifest.chainId}`,
      );
    }

    const checkpoint = await checkpointStore.load();
    return new ReferenceNodeService(
      manifest,
      rpc,
      decoder,
      checkpointStore,
      checkpoint,
      options,
    );
  }

  async syncTo(targetBlock?: number): Promise<BlockCursor | undefined> {
    const chainId = await this.rpc.chainId();
    if (chainId !== this.manifest.chainId) {
      throw new Error(
        `RPC chainId ${chainId} does not match manifest chainId ${this.manifest.chainId}`,
      );
    }

    await this.reconcileCanonicalHead();

    const target = targetBlock ?? await this.rpc.blockNumber();
    if (!Number.isSafeInteger(target) || target < 0) {
      throw new RangeError("targetBlock must be a non-negative safe integer");
    }

    let next = this.indexer.head()?.number;
    next = next === undefined ? this.manifest.deploymentBlock : next + 1;

    let appliedSincePersist = 0;
    while (next <= target) {
      const block = await this.fetchIndexedBlock(next);
      this.indexer.applyBlock(block);
      appliedSincePersist += 1;

      if (appliedSincePersist >= this.persistEveryBlocks) {
        await this.checkpointStore.save(this.indexer.checkpoint());
        appliedSincePersist = 0;
      }

      next += 1;
    }

    if (appliedSincePersist !== 0) {
      await this.checkpointStore.save(this.indexer.checkpoint());
    }

    return this.indexer.head();
  }

  async reconcileCanonicalHead(): Promise<void> {
    const head = this.indexer.head();
    if (!head) return;

    const canonicalHead = await this.rpc.blockHeader(head.number);
    if (canonicalHead.hash === head.hash) return;

    const retained = this.indexer.retainedBlocks();
    let common: BlockCursor | undefined;
    for (let i = retained.length - 1; i >= 0; i -= 1) {
      const candidate = retained[i];
      const canonical = await this.rpc.blockHeader(candidate.number);
      if (canonical.hash === candidate.hash) {
        common = candidate;
        break;
      }
    }

    if (!common) {
      throw new IndexerError(
        "canonical reorg exceeds retained history; restore a finalized checkpoint",
      );
    }

    this.indexer.rollbackTo(common);
    await this.checkpointStore.save(this.indexer.checkpoint());
  }

  private async fetchIndexedBlock(blockNumber: number): Promise<IndexedBlock> {
    const [header, rawLogs] = await Promise.all([
      this.rpc.blockHeader(blockNumber),
      this.rpc.logs(blockNumber, this.addresses),
    ]);

    const logs: ProtocolLog[] = [];
    for (const raw of rawLogs) {
      if (raw.blockHash !== header.hash) continue;
      const event = this.decoder(raw, this.manifest);
      if (!event) continue;

      logs.push({
        blockNumber: fromHex(raw.blockNumber, "log.blockNumber"),
        blockHash: raw.blockHash,
        transactionIndex: fromHex(raw.transactionIndex, "transactionIndex"),
        logIndex: fromHex(raw.logIndex, "logIndex"),
        address: raw.address,
        event,
      });
    }

    return {
      chainId: this.manifest.chainId,
      number: blockNumber,
      hash: header.hash,
      parentHash: header.parentHash,
      logs,
    };
  }
}

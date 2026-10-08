export type Address = `0x${string}`;
export type Side = 0 | 1;
export interface BlockRef { number: number; hash: string; parentHash: string; }
export interface NormalizedEvent {
  chainId: number;
  blockNumber: number;
  transactionIndex: number;
  logIndex: number;
  blockHash: string;
  address: Address;
  marketId?: string;
  name: string;
  args: Record<string, unknown>;
}
export interface PoolState { remainingLots: bigint; generation: number; }
export interface AdvancedState { owner?: Address; active: boolean; dormant?: boolean; expiry: bigint; resting: boolean; triggerAboveOrEqual?: boolean; triggerTick?: number; }
export interface ManagedQuoteState { shares: bigint; generation: number; }
export interface PortfolioLockState { equity: bigint; requirement: bigint; lockedCollateral: bigint; }
export interface IndexState {
  pools: Map<string, PoolState>;
  conditionals: Map<string, AdvancedState>;
  trailing: Map<string, AdvancedState>;
  managedQuotes: Map<string, ManagedQuoteState>;
  portfolioLocks: Map<Address, PortfolioLockState>;
  knownMakerKeys: Map<Address, Set<string>>;
  activeConditionalIds: Map<Address, Set<string>>;
  activeTrailingIds: Map<Address, Set<string>>;
}
export type KeeperTask =
  | { kind: "expireConditional"; marketId: string; orderId: bigint }
  | { kind: "executeConditional"; marketId: string; orderId: bigint }
  | { kind: "expireTrailing"; marketId: string; orderId: bigint }
  | { kind: "checkTrailing"; marketId: string; orderId: bigint }
  | { kind: "syncResting"; marketId: string; orderId: bigint }
  | { kind: "liquidationCandidate"; account: Address; knownMakerKeys: readonly string[]; conditionalIds: readonly bigint[]; trailingIds: readonly bigint[] };
export interface KeeperContext { now: bigint; markTicks: Readonly<Record<string, number>>; portfolioHealth?: Readonly<Record<Address, { equity: bigint; requirement: bigint }>>; }
export interface OperatorMarketManifest {
  id: string;
  core: Address;
  advanced: Address;
  executionStrategy?: Address;
  marketMaker?: Address;
  liquidation?: Address;
  portfolioLiquidation?: Address;
  integrationLens?: Address;
  oracle: Address;
  portfolioMarketIndex?: number;
}
export interface OperatorManifest {
  schemaVersion: 1;
  chainId: number;
  deploymentBlock: number;
  collateral: { token: Address; decimals: number };
  portfolio?: { coordinator: Address; policy: Address; vault: Address };
  markets: OperatorMarketManifest[];
}
export interface SerializedIndexState {
  pools: [string, { remainingLots: string; generation: number }][];
  conditionals: [string, Omit<AdvancedState, "expiry"> & { expiry: string }][];
  trailing: [string, Omit<AdvancedState, "expiry"> & { expiry: string }][];
  managedQuotes: [string, { shares: string; generation: number }][];
  portfolioLocks: [Address, { equity: string; requirement: string; lockedCollateral: string }][];
  knownMakerKeys: [Address, string[]][];
  activeConditionalIds: [Address, string[]][];
  activeTrailingIds: [Address, string[]][];
}
export interface OperatorCheckpoint {
  version: 1;
  chainId: number;
  deploymentBlock: number;
  manifestIdentity: string;
  branchEpoch?: number;
  head?: BlockRef;
  state: SerializedIndexState;
}
export interface OperatorRpcAdapter {
  getChainId(): Promise<number>;
  getHeadBlockNumber(): Promise<number>;
  getBlock(blockNumber: number): Promise<BlockRef>;
  getEvents(block: BlockRef, manifest: OperatorManifest): Promise<readonly NormalizedEvent[]>;
  getMarkTicks(manifest: OperatorManifest): Promise<Readonly<Record<string, number>>>;
  getPortfolioHealth?(accounts: readonly Address[], manifest: OperatorManifest): Promise<Readonly<Record<Address, { equity: bigint; requirement: bigint }>>>;
  getTimestamp?(): Promise<bigint>;
}
export interface KeeperExecutor {
  simulate(task: KeeperTask): Promise<boolean>;
  submit(task: KeeperTask): Promise<string>;
}
export interface IdempotentKeeperExecutor {
  simulate(task: KeeperTask): Promise<boolean>;
  alreadySubmitted(idempotencyKey: string): Promise<boolean>;
  submit(task: KeeperTask, idempotencyKey: string): Promise<string>;
}
export interface OperatorSyncOptions {
  confirmationDepth?: number;
  maxBlocksPerSync?: number;
}
export interface OperatorCheckpointStore {
  load(manifestIdentity: string): Promise<OperatorCheckpoint | undefined>;
  save(manifestIdentity: string, checkpoint: OperatorCheckpoint): Promise<void>;
}
export interface OperatorSyncResult {
  fromBlock: number;
  toBlock: number;
  remoteHead: number;
  safeHead: number;
  appliedBlocks: number;
  rolledBackTo?: number;
  tasks: KeeperTask[];
}
export interface OperatorCycleResult extends OperatorSyncResult {
  restoredCheckpoint: boolean;
  submitted: { task: KeeperTask; transactionId: string; idempotencyKey: string }[];
}
export declare class ReferenceIndexer {
  readonly chainId: number;
  readonly state: IndexState;
  constructor(chainId: number, maxReorgDepth?: number);
  headBlock(): BlockRef | undefined;
  branchEpoch(): number;
  retainedBlocks(): BlockRef[];
  checkpoint(manifestInput: unknown): OperatorCheckpoint;
  restoreCheckpoint(checkpoint: OperatorCheckpoint, manifestInput: unknown): void;
  applyBlock(block: BlockRef, events: readonly NormalizedEvent[]): void;
  rollbackTo(blockNumber: number): void;
  applyEvent(event: NormalizedEvent): void;
}
export declare function planKeeperTasks(state: IndexState, context: KeeperContext): KeeperTask[];
export declare function operatorManifestIdentity(manifestInput: unknown): string;
export declare function validateOperatorManifest(input: unknown): OperatorManifest;
export declare function serializeState(state: IndexState): SerializedIndexState;
export declare function deserializeState(state: SerializedIndexState): IndexState;
export declare function knownOperatorAccounts(state: IndexState): Address[];
export declare function syncOperatorOnce(manifestInput: unknown, indexer: ReferenceIndexer, adapter: OperatorRpcAdapter, options?: OperatorSyncOptions): Promise<OperatorSyncResult>;
export declare function executeKeeperTasks(tasks: readonly KeeperTask[], executor: KeeperExecutor): Promise<{ task: KeeperTask; transactionId: string }[]>;
export declare function keeperTaskId(manifestInput: unknown, branchEpoch: number, task: KeeperTask): string;
export declare function executeKeeperTasksIdempotent(manifestInput: unknown, branchEpoch: number, tasks: readonly KeeperTask[], executor: IdempotentKeeperExecutor): Promise<{ task: KeeperTask; transactionId: string; idempotencyKey: string }[]>;
export declare function runOperatorCycle(manifestInput: unknown, indexer: ReferenceIndexer, adapter: OperatorRpcAdapter, store: OperatorCheckpointStore, executor?: IdempotentKeeperExecutor, options?: OperatorSyncOptions): Promise<OperatorCycleResult>;

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
export declare class ReferenceIndexer {
  readonly chainId: number;
  readonly state: IndexState;
  constructor(chainId: number, maxReorgDepth?: number);
  headBlock(): BlockRef | undefined;
  applyBlock(block: BlockRef, events: readonly NormalizedEvent[]): void;
  rollbackTo(blockNumber: number): void;
  applyEvent(event: NormalizedEvent): void;
}
export declare function planKeeperTasks(state: IndexState, context: KeeperContext): KeeperTask[];

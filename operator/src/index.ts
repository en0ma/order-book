export type Address = `0x${string}`;
export type Side = 0 | 1;

export interface BlockRef {
  number: number;
  hash: string;
  parentHash: string;
}

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

export interface PoolState {
  remainingLots: bigint;
  generation: number;
}

export interface AdvancedState {
  owner?: Address;
  active: boolean;
  dormant?: boolean;
  expiry: bigint;
  resting: boolean;
  triggerAboveOrEqual?: boolean;
  triggerTick?: number;
}

export interface ManagedQuoteState {
  shares: bigint;
  generation: number;
}

export interface PortfolioLockState {
  equity: bigint;
  requirement: bigint;
  lockedCollateral: bigint;
}

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
  | {
      kind: "liquidationCandidate";
      account: Address;
      knownMakerKeys: readonly string[];
      conditionalIds: readonly bigint[];
      trailingIds: readonly bigint[];
    };

export interface KeeperContext {
  now: bigint;
  markTicks: Readonly<Record<string, number>>;
  portfolioHealth?: Readonly<Record<Address, { equity: bigint; requirement: bigint }>>;
}

export interface OperatorMarketManifest {
  id: string;
  core: Address;
  advanced: Address;
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
  head?: BlockRef;
  state: SerializedIndexState;
}

export interface OperatorRpcAdapter {
  getChainId(): Promise<number>;
  getHeadBlockNumber(): Promise<number>;
  getBlock(blockNumber: number): Promise<BlockRef>;
  getEvents(
    block: BlockRef,
    manifest: OperatorManifest,
  ): Promise<readonly NormalizedEvent[]>;
  getMarkTicks(manifest: OperatorManifest): Promise<Readonly<Record<string, number>>>;
  getPortfolioHealth?(
    accounts: readonly Address[],
    manifest: OperatorManifest,
  ): Promise<Readonly<Record<Address, { equity: bigint; requirement: bigint }>>>;
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

type Snapshot = {
  block: BlockRef;
  state: IndexState;
};

function copySetMap(source: Map<Address, Set<string>>): Map<Address, Set<string>> {
  return new Map([...source].map(([key, values]) => [key, new Set(values)]));
}

function cloneState(state: IndexState): IndexState {
  return {
    pools: new Map([...state.pools].map(([k, v]) => [k, { ...v }])),
    conditionals: new Map([...state.conditionals].map(([k, v]) => [k, { ...v }])),
    trailing: new Map([...state.trailing].map(([k, v]) => [k, { ...v }])),
    managedQuotes: new Map([...state.managedQuotes].map(([k, v]) => [k, { ...v }])),
    portfolioLocks: new Map([...state.portfolioLocks].map(([k, v]) => [k, { ...v }])),
    knownMakerKeys: copySetMap(state.knownMakerKeys),
    activeConditionalIds: copySetMap(state.activeConditionalIds),
    activeTrailingIds: copySetMap(state.activeTrailingIds),
  };
}

function emptyState(): IndexState {
  return {
    pools: new Map(),
    conditionals: new Map(),
    trailing: new Map(),
    managedQuotes: new Map(),
    portfolioLocks: new Map(),
    knownMakerKeys: new Map(),
    activeConditionalIds: new Map(),
    activeTrailingIds: new Map(),
  };
}

function requireMarket(event: NormalizedEvent): string {
  if (!event.marketId) throw new Error(`${event.name} requires marketId`);
  return event.marketId;
}

function asBigInt(value: unknown, field: string): bigint {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isSafeInteger(value)) return BigInt(value);
  if (typeof value === "string" && /^-?[0-9]+$/.test(value)) return BigInt(value);
  throw new TypeError(`${field} must be an integer-like value`);
}

function asNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw new TypeError(`${field} must be a safe integer`);
  }
  return value;
}

function asAddress(value: unknown, field: string): Address {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new TypeError(`${field} must be an address`);
  }
  return value as Address;
}

function poolKey(marketId: string, side: number, tick: number): string {
  return `${marketId}:${side}:${tick}`;
}

function orderKey(marketId: string, orderId: bigint): string {
  return `${marketId}:${orderId}`;
}

function makerKey(marketId: string, side: number, tick: number): string {
  return `${marketId}:${side}:${tick}`;
}

function managedKey(marketId: string, maker: Address, side: number, tick: number): string {
  return `${marketId}:${maker.toLowerCase()}:${side}:${tick}`;
}

function addOwned(map: Map<Address, Set<string>>, owner: Address, key: string): void {
  const set = map.get(owner) ?? new Set<string>();
  set.add(key);
  map.set(owner, set);
}

function deleteOwned(map: Map<Address, Set<string>>, owner: Address | undefined, key: string): void {
  if (!owner) return;
  const set = map.get(owner);
  if (!set) return;
  set.delete(key);
  if (set.size === 0) map.delete(owner);
}

function sortedEvents(events: readonly NormalizedEvent[]): NormalizedEvent[] {
  return [...events].sort((a, b) =>
    a.blockNumber - b.blockNumber
    || a.transactionIndex - b.transactionIndex
    || a.logIndex - b.logIndex
  );
}

export class ReferenceIndexer {
  readonly chainId: number;
  readonly state: IndexState;

  private head?: BlockRef;
  private readonly snapshots = new Map<number, Snapshot>();
  private readonly maxReorgDepth: number;

  constructor(chainId: number, maxReorgDepth = 64) {
    if (!Number.isInteger(chainId) || chainId <= 0) throw new RangeError("chainId must be positive");
    if (!Number.isSafeInteger(maxReorgDepth) || maxReorgDepth < 1) {
      throw new RangeError("maxReorgDepth must be a positive safe integer");
    }
    this.chainId = chainId;
    this.maxReorgDepth = maxReorgDepth;
    this.state = emptyState();
  }

  headBlock(): BlockRef | undefined {
    return this.head ? { ...this.head } : undefined;
  }

  retainedBlocks(): BlockRef[] {
    return [...this.snapshots.values()]
      .map((snapshot) => ({ ...snapshot.block }))
      .sort((a, b) => a.number - b.number);
  }

  checkpoint(manifestInput: unknown): OperatorCheckpoint {
    const manifest = validateOperatorManifest(manifestInput);
    if (manifest.chainId !== this.chainId) {
      throw new Error("manifest chainId does not match indexer");
    }
    return {
      version: 1,
      chainId: this.chainId,
      deploymentBlock: manifest.deploymentBlock,
      manifestIdentity: operatorManifestIdentity(manifest),
      head: this.headBlock(),
      state: serializeState(this.state),
    };
  }

  restoreCheckpoint(checkpoint: OperatorCheckpoint, manifestInput: unknown): void {
    const manifest = validateOperatorManifest(manifestInput);
    if (
      checkpoint.version !== 1
      || checkpoint.chainId !== this.chainId
      || checkpoint.chainId !== manifest.chainId
      || checkpoint.deploymentBlock !== manifest.deploymentBlock
      || checkpoint.manifestIdentity !== operatorManifestIdentity(manifest)
    ) {
      throw new Error("checkpoint does not match deployment manifest");
    }
    const restored = deserializeState(checkpoint.state);
    this.restore(restored);
    this.head = checkpoint.head ? { ...checkpoint.head } : undefined;
    this.snapshots.clear();
    if (this.head) {
      this.snapshots.set(this.head.number, {
        block: { ...this.head },
        state: cloneState(this.state),
      });
    }
  }

  applyBlock(block: BlockRef, events: readonly NormalizedEvent[]): void {
    if (!Number.isSafeInteger(block.number) || block.number < 0) {
      throw new RangeError("block number must be a non-negative safe integer");
    }
    if (this.head) {
      if (block.number !== this.head.number + 1 || block.parentHash !== this.head.hash) {
        throw new Error("non-canonical block: rollback to the common ancestor first");
      }
    }

    const before = cloneState(this.state);
    try {
      for (const event of sortedEvents(events)) {
        if (
          event.chainId !== this.chainId
          || event.blockNumber !== block.number
          || event.blockHash !== block.hash
        ) {
          throw new Error("event does not belong to supplied block/chain");
        }
        this.applyEvent(event);
      }
    } catch (error) {
      this.restore(before);
      throw error;
    }

    this.head = { ...block };
    this.snapshots.set(block.number, { block: { ...block }, state: cloneState(this.state) });
    const minRetained = block.number - this.maxReorgDepth + 1;
    for (const height of [...this.snapshots.keys()]) {
      if (height < minRetained) this.snapshots.delete(height);
    }
  }

  rollbackTo(blockNumber: number): void {
    if (blockNumber < 0) {
      this.restore(emptyState());
      this.head = undefined;
      this.snapshots.clear();
      return;
    }
    const snapshot = this.snapshots.get(blockNumber);
    if (!snapshot) throw new Error("rollback checkpoint unavailable");
    this.restore(snapshot.state);
    this.head = { ...snapshot.block };
    for (const height of [...this.snapshots.keys()]) {
      if (height > blockNumber) this.snapshots.delete(height);
    }
  }

  applyEvent(event: NormalizedEvent): void {
    const marketId = event.marketId;
    const a = event.args;

    switch (event.name) {
      case "LiquidityAdded": {
        const market = requireMarket(event);
        const side = asNumber(a.side, "side");
        const tick = asNumber(a.tick, "tick");
        const lots = asBigInt(a.lots, "lots");
        const generation = asNumber(a.generation, "generation");
        const key = poolKey(market, side, tick);
        const prior = this.state.pools.get(key);
        this.state.pools.set(key, {
          remainingLots: (prior?.remainingLots ?? 0n) + lots,
          generation,
        });
        if (a.account !== undefined) {
          addOwned(
            this.state.knownMakerKeys,
            asAddress(a.account, "account"),
            makerKey(market, side, tick),
          );
        }
        break;
      }
      case "LiquidityRemoved": {
        const market = requireMarket(event);
        const side = asNumber(a.side, "side");
        const tick = asNumber(a.tick, "tick");
        const lots = asBigInt(a.lots, "lots");
        const generation = asNumber(a.generation, "generation");
        const key = poolKey(market, side, tick);
        const prior = this.state.pools.get(key) ?? { remainingLots: 0n, generation };
        if (lots > prior.remainingLots) throw new Error("liquidity removal exceeds replayed pool");
        this.state.pools.set(key, {
          remainingLots: prior.remainingLots - lots,
          generation,
        });
        break;
      }
      case "Trade": {
        const market = requireMarket(event);
        const takerSide = asNumber(a.side, "side");
        const makerSide = takerSide === 0 ? 1 : 0;
        const tick = asNumber(a.tick, "tick");
        const filled = asBigInt(a.lots, "lots");
        const key = poolKey(market, makerSide, tick);
        const prior = this.state.pools.get(key);
        if (!prior || filled > prior.remainingLots) {
          throw new Error("trade exceeds replayed maker pool");
        }
        const remainingLots = prior.remainingLots - filled;
        this.state.pools.set(key, {
          remainingLots,
          generation: remainingLots === 0n ? prior.generation + 1 : prior.generation,
        });
        break;
      }
      case "ConditionalOrderPlaced": {
        const market = requireMarket(event);
        const id = asBigInt(a.orderId, "orderId");
        const owner = asAddress(a.owner, "owner");
        const key = orderKey(market, id);
        this.state.conditionals.set(key, {
          owner,
          active: true,
          dormant: false,
          expiry: 0n,
          resting: false,
          triggerAboveOrEqual: Boolean(a.triggerAboveOrEqual),
          triggerTick: asNumber(a.triggerTick, "triggerTick"),
        });
        addOwned(this.state.activeConditionalIds, owner, key);
        break;
      }
      case "OTOLinked": {
        const market = requireMarket(event);
        const childId = asBigInt(a.childOrderId, "childOrderId");
        const key = orderKey(market, childId);
        const state = this.state.conditionals.get(key);
        if (state) {
          state.active = false;
          state.dormant = true;
          deleteOwned(this.state.activeConditionalIds, state.owner, key);
        }
        break;
      }
      case "OTOActivated": {
        const market = requireMarket(event);
        const childId = asBigInt(a.childOrderId, "childOrderId");
        const key = orderKey(market, childId);
        const state = this.state.conditionals.get(key);
        if (state) {
          state.active = true;
          state.dormant = false;
          if (state.owner) addOwned(this.state.activeConditionalIds, state.owner, key);
        }
        break;
      }
      case "OTOResized":
        break;
      case "ConditionalExpirySet": {
        const market = requireMarket(event);
        const key = orderKey(market, asBigInt(a.orderId, "orderId"));
        const state = this.state.conditionals.get(key);
        if (state) state.expiry = asBigInt(a.expiry, "expiry");
        break;
      }
      case "RestingOrderLinked": {
        const market = requireMarket(event);
        const key = orderKey(market, asBigInt(a.orderId ?? a.parentOrderId, "orderId"));
        const state = this.state.conditionals.get(key);
        if (state) state.resting = true;
        break;
      }
      case "RestingOrderSynced": {
        const market = requireMarket(event);
        const key = orderKey(market, asBigInt(a.orderId ?? a.parentOrderId, "orderId"));
        const state = this.state.conditionals.get(key);
        if (state && asBigInt(a.remainingLots, "remainingLots") === 0n) {
          state.resting = false;
          state.expiry = 0n;
        }
        break;
      }
      case "RestingOrderCancelled": {
        const market = requireMarket(event);
        const key = orderKey(market, asBigInt(a.orderId ?? a.parentOrderId, "orderId"));
        const state = this.state.conditionals.get(key);
        if (state) {
          state.resting = false;
          state.expiry = 0n;
        }
        break;
      }
      case "ConditionalOrderExecuted": {
        const market = requireMarket(event);
        const key = orderKey(market, asBigInt(a.orderId, "orderId"));
        const state = this.state.conditionals.get(key);
        if (state) {
          state.active = false;
          if (!state.resting) state.expiry = 0n;
          deleteOwned(this.state.activeConditionalIds, state.owner, key);
        }
        break;
      }
      case "ConditionalOrderCancelled":
      case "ConditionalOrderExpired": {
        const market = requireMarket(event);
        const key = orderKey(market, asBigInt(a.orderId, "orderId"));
        const state = this.state.conditionals.get(key);
        if (state) {
          state.active = false;
          state.resting = false;
          state.expiry = 0n;
          deleteOwned(this.state.activeConditionalIds, state.owner, key);
        }
        break;
      }
      case "TrailingOrderPlaced": {
        const market = requireMarket(event);
        const id = asBigInt(a.orderId, "orderId");
        const owner = asAddress(a.owner, "owner");
        const key = orderKey(market, id);
        this.state.trailing.set(key, { owner, active: true, expiry: 0n, resting: false });
        addOwned(this.state.activeTrailingIds, owner, key);
        break;
      }
      case "TrailingExpirySet": {
        const market = requireMarket(event);
        const key = orderKey(market, asBigInt(a.orderId, "orderId"));
        const state = this.state.trailing.get(key);
        if (state) state.expiry = asBigInt(a.expiry, "expiry");
        break;
      }
      case "TrailingOrderCancelled":
      case "TrailingOrderExpired":
      case "TrailingOrderExecuted": {
        const market = requireMarket(event);
        const key = orderKey(market, asBigInt(a.orderId, "orderId"));
        const state = this.state.trailing.get(key);
        if (state) {
          state.active = false;
          state.expiry = 0n;
          deleteOwned(this.state.activeTrailingIds, state.owner, key);
        }
        break;
      }
      case "ManagedQuoteUpdated": {
        const market = requireMarket(event);
        const maker = asAddress(a.maker, "maker");
        this.state.managedQuotes.set(
          managedKey(market, maker, asNumber(a.side, "side"), asNumber(a.tick, "tick")),
          {
            shares: asBigInt(a.shares, "shares"),
            generation: asNumber(a.generation, "generation"),
          },
        );
        break;
      }
      case "ManagedQuoteRemoved": {
        const market = requireMarket(event);
        const maker = asAddress(a.maker, "maker");
        this.state.managedQuotes.delete(
          managedKey(market, maker, asNumber(a.side, "side"), asNumber(a.tick, "tick")),
        );
        break;
      }
      case "PortfolioLockSynchronized": {
        const account = asAddress(a.account, "account");
        this.state.portfolioLocks.set(account, {
          equity: asBigInt(a.equity, "equity"),
          requirement: asBigInt(a.requirement, "requirement"),
          lockedCollateral: asBigInt(a.lockedCollateral, "lockedCollateral"),
        });
        break;
      }
      default:
        break;
    }

  }

  private restore(snapshot: IndexState): void {
    const next = cloneState(snapshot);
    this.state.pools = next.pools;
    this.state.conditionals = next.conditionals;
    this.state.trailing = next.trailing;
    this.state.managedQuotes = next.managedQuotes;
    this.state.portfolioLocks = next.portfolioLocks;
    this.state.knownMakerKeys = next.knownMakerKeys;
    this.state.activeConditionalIds = next.activeConditionalIds;
    this.state.activeTrailingIds = next.activeTrailingIds;
  }
}

function splitOrderKey(key: string): [string, bigint] {
  const separator = key.lastIndexOf(":");
  if (separator <= 0) throw new Error("invalid order key");
  return [key.slice(0, separator), BigInt(key.slice(separator + 1))];
}

export function planKeeperTasks(
  state: IndexState,
  context: KeeperContext,
): KeeperTask[] {
  const tasks: KeeperTask[] = [];

  for (const [key, order] of state.conditionals) {
    if (!order.active && !order.resting) continue;
    const [marketId, orderId] = splitOrderKey(key);

    if (order.expiry !== 0n && context.now >= order.expiry) {
      tasks.push({ kind: "expireConditional", marketId, orderId });
      continue;
    }

    if (order.resting) {
      tasks.push({ kind: "syncResting", marketId, orderId });
    } else if (
      order.active
      && order.triggerTick !== undefined
      && order.triggerAboveOrEqual !== undefined
      && context.markTicks[marketId] !== undefined
    ) {
      const mark = context.markTicks[marketId];
      const triggered = order.triggerAboveOrEqual
        ? mark >= order.triggerTick
        : mark <= order.triggerTick;
      if (triggered) tasks.push({ kind: "executeConditional", marketId, orderId });
    }
  }

  for (const [key, order] of state.trailing) {
    if (!order.active) continue;
    const [marketId, orderId] = splitOrderKey(key);
    if (order.expiry !== 0n && context.now >= order.expiry) {
      tasks.push({ kind: "expireTrailing", marketId, orderId });
    } else {
      tasks.push({ kind: "checkTrailing", marketId, orderId });
    }
  }

  for (const [account, health] of Object.entries(context.portfolioHealth ?? {}) as [
    Address,
    { equity: bigint; requirement: bigint },
  ][]) {
    if (health.equity >= health.requirement) continue;
    tasks.push({
      kind: "liquidationCandidate",
      account,
      knownMakerKeys: [...(state.knownMakerKeys.get(account) ?? [])].sort(),
      conditionalIds: [...(state.activeConditionalIds.get(account) ?? [])]
        .map((key) => splitOrderKey(key)[1])
        .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)),
      trailingIds: [...(state.activeTrailingIds.get(account) ?? [])]
        .map((key) => splitOrderKey(key)[1])
        .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)),
    });
  }

  return tasks;
}


function isAddress(value: unknown): value is Address {
  return (
    typeof value === "string"
    && /^0x[0-9a-fA-F]{40}$/.test(value)
    && !/^0x0{40}$/i.test(value)
  );
}

function expectObject(value: unknown, field: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function expectAddress(value: unknown, field: string): Address {
  if (!isAddress(value)) throw new TypeError(`${field} must be an address`);
  return value;
}

function expectSafeInteger(value: unknown, field: string, minimum = 0): number {
  if (
    typeof value !== "number"
    || !Number.isSafeInteger(value)
    || value < minimum
  ) {
    throw new TypeError(`${field} must be a safe integer >= ${minimum}`);
  }
  return value;
}

export function operatorManifestIdentity(manifestInput: unknown): string {
  const manifest = validateOperatorManifest(manifestInput);
  const marketIdentity = [...manifest.markets]
    .sort((a, b) => a.id.localeCompare(b.id))
    .map((market) => [
      market.id,
      market.core.toLowerCase(),
      market.advanced.toLowerCase(),
      market.marketMaker?.toLowerCase() ?? "",
      market.liquidation?.toLowerCase() ?? "",
      market.portfolioLiquidation?.toLowerCase() ?? "",
      market.integrationLens?.toLowerCase() ?? "",
      market.oracle.toLowerCase(),
      market.portfolioMarketIndex ?? "",
    ].join(":"))
    .join("|");
  const portfolioIdentity = manifest.portfolio
    ? [
        manifest.portfolio.coordinator.toLowerCase(),
        manifest.portfolio.policy.toLowerCase(),
        manifest.portfolio.vault.toLowerCase(),
      ].join(":")
    : "";
  return [
    manifest.schemaVersion,
    manifest.chainId,
    manifest.deploymentBlock,
    manifest.collateral.token.toLowerCase(),
    manifest.collateral.decimals,
    portfolioIdentity,
    marketIdentity,
  ].join("/");
}

export function validateOperatorManifest(input: unknown): OperatorManifest {
  const root = expectObject(input, "manifest");
  if (root.schemaVersion !== 1) throw new TypeError("unsupported manifest schemaVersion");

  const chainId = expectSafeInteger(root.chainId, "chainId", 1);
  const deploymentBlock = expectSafeInteger(root.deploymentBlock, "deploymentBlock");
  const collateralRaw = expectObject(root.collateral, "collateral");
  const collateral = {
    token: expectAddress(collateralRaw.token, "collateral.token"),
    decimals: expectSafeInteger(collateralRaw.decimals, "collateral.decimals"),
  };
  if (collateral.decimals > 255) throw new RangeError("collateral.decimals out of range");

  if (!Array.isArray(root.markets) || root.markets.length === 0) {
    throw new TypeError("markets must be a non-empty array");
  }

  const ids = new Set<string>();
  const markets = root.markets.map((entry, index): OperatorMarketManifest => {
    const market = expectObject(entry, `markets[${index}]`);
    if (typeof market.id !== "string" || market.id.length === 0) {
      throw new TypeError(`markets[${index}].id must be non-empty`);
    }
    if (ids.has(market.id)) throw new TypeError("duplicate market id");
    ids.add(market.id);

    const result: OperatorMarketManifest = {
      id: market.id,
      core: expectAddress(market.core, `markets[${index}].core`),
      advanced: expectAddress(market.advanced, `markets[${index}].advanced`),
      oracle: expectAddress(market.oracle, `markets[${index}].oracle`),
    };
    for (const field of [
      "marketMaker",
      "liquidation",
      "portfolioLiquidation",
      "integrationLens",
    ] as const) {
      if (market[field] !== undefined) {
        result[field] = expectAddress(market[field], `markets[${index}].${field}`);
      }
    }
    if (market.portfolioMarketIndex !== undefined) {
      result.portfolioMarketIndex = expectSafeInteger(
        market.portfolioMarketIndex,
        `markets[${index}].portfolioMarketIndex`,
      );
    }
    return result;
  });

  let portfolio: OperatorManifest["portfolio"];
  if (root.portfolio !== undefined) {
    const raw = expectObject(root.portfolio, "portfolio");
    portfolio = {
      coordinator: expectAddress(raw.coordinator, "portfolio.coordinator"),
      policy: expectAddress(raw.policy, "portfolio.policy"),
      vault: expectAddress(raw.vault, "portfolio.vault"),
    };
    const indexes = new Set<number>();
    for (const market of markets) {
      if (market.portfolioMarketIndex === undefined) {
        throw new TypeError("portfolio market missing portfolioMarketIndex");
      }
      if (indexes.has(market.portfolioMarketIndex)) {
        throw new TypeError("duplicate portfolioMarketIndex");
      }
      indexes.add(market.portfolioMarketIndex);
    }
  } else if (markets.some((market) => market.portfolioMarketIndex !== undefined)) {
    throw new TypeError("standalone manifest cannot include portfolioMarketIndex");
  }

  return {
    schemaVersion: 1,
    chainId,
    deploymentBlock,
    collateral,
    ...(portfolio ? { portfolio } : {}),
    markets,
  };
}

export function serializeState(state: IndexState): SerializedIndexState {
  const sets = (source: Map<Address, Set<string>>): [Address, string[]][] =>
    [...source].map(([address, values]) => [address, [...values].sort()]);

  return {
    pools: [...state.pools].map(([key, value]) => [key, {
      remainingLots: value.remainingLots.toString(),
      generation: value.generation,
    }]),
    conditionals: [...state.conditionals].map(([key, value]) => [key, {
      ...value,
      expiry: value.expiry.toString(),
    }]),
    trailing: [...state.trailing].map(([key, value]) => [key, {
      ...value,
      expiry: value.expiry.toString(),
    }]),
    managedQuotes: [...state.managedQuotes].map(([key, value]) => [key, {
      shares: value.shares.toString(),
      generation: value.generation,
    }]),
    portfolioLocks: [...state.portfolioLocks].map(([key, value]) => [key, {
      equity: value.equity.toString(),
      requirement: value.requirement.toString(),
      lockedCollateral: value.lockedCollateral.toString(),
    }]),
    knownMakerKeys: sets(state.knownMakerKeys),
    activeConditionalIds: sets(state.activeConditionalIds),
    activeTrailingIds: sets(state.activeTrailingIds),
  };
}

export function deserializeState(state: SerializedIndexState): IndexState {
  const setMap = (entries: [Address, string[]][]): Map<Address, Set<string>> =>
    new Map(entries.map(([address, values]) => [address, new Set(values)]));

  return {
    pools: new Map(state.pools.map(([key, value]) => [key, {
      remainingLots: BigInt(value.remainingLots),
      generation: value.generation,
    }])),
    conditionals: new Map(state.conditionals.map(([key, value]) => [key, {
      ...value,
      expiry: BigInt(value.expiry),
    }])),
    trailing: new Map(state.trailing.map(([key, value]) => [key, {
      ...value,
      expiry: BigInt(value.expiry),
    }])),
    managedQuotes: new Map(state.managedQuotes.map(([key, value]) => [key, {
      shares: BigInt(value.shares),
      generation: value.generation,
    }])),
    portfolioLocks: new Map(state.portfolioLocks.map(([key, value]) => [key, {
      equity: BigInt(value.equity),
      requirement: BigInt(value.requirement),
      lockedCollateral: BigInt(value.lockedCollateral),
    }])),
    knownMakerKeys: setMap(state.knownMakerKeys),
    activeConditionalIds: setMap(state.activeConditionalIds),
    activeTrailingIds: setMap(state.activeTrailingIds),
  };
}

export function knownOperatorAccounts(state: IndexState): Address[] {
  const accounts = new Set<Address>();
  for (const account of state.knownMakerKeys.keys()) accounts.add(account);
  for (const account of state.activeConditionalIds.keys()) accounts.add(account);
  for (const account of state.activeTrailingIds.keys()) accounts.add(account);
  for (const account of state.portfolioLocks.keys()) accounts.add(account);
  return [...accounts].sort();
}

async function reconcileReorg(
  indexer: ReferenceIndexer,
  adapter: OperatorRpcAdapter,
): Promise<number | undefined> {
  const head = indexer.headBlock();
  if (!head) return undefined;

  const canonicalHead = await adapter.getBlock(head.number);
  if (canonicalHead.hash === head.hash) return undefined;

  const retained = indexer.retainedBlocks().sort((a, b) => b.number - a.number);
  for (const candidate of retained) {
    const canonical = await adapter.getBlock(candidate.number);
    if (canonical.hash === candidate.hash) {
      indexer.rollbackTo(candidate.number);
      return candidate.number;
    }
  }
  throw new Error("reorg exceeds retained operator history");
}

function validateSyncOptions(options: OperatorSyncOptions): {
  confirmationDepth: number;
  maxBlocksPerSync: number;
} {
  const confirmationDepth = options.confirmationDepth ?? 0;
  const maxBlocksPerSync = options.maxBlocksPerSync ?? Number.MAX_SAFE_INTEGER;
  if (!Number.isSafeInteger(confirmationDepth) || confirmationDepth < 0) {
    throw new RangeError("confirmationDepth must be a non-negative safe integer");
  }
  if (!Number.isSafeInteger(maxBlocksPerSync) || maxBlocksPerSync < 1) {
    throw new RangeError("maxBlocksPerSync must be a positive safe integer");
  }
  return { confirmationDepth, maxBlocksPerSync };
}

export async function syncOperatorOnce(
  manifestInput: unknown,
  indexer: ReferenceIndexer,
  adapter: OperatorRpcAdapter,
  options: OperatorSyncOptions = {},
): Promise<OperatorSyncResult> {
  const manifest = validateOperatorManifest(manifestInput);
  if (manifest.chainId !== indexer.chainId) {
    throw new Error("manifest chainId does not match indexer");
  }
  const rpcChainId = await adapter.getChainId();
  if (rpcChainId !== manifest.chainId) {
    throw new Error("RPC chainId does not match manifest");
  }
  const { confirmationDepth, maxBlocksPerSync } = validateSyncOptions(options);

  const rolledBackTo = await reconcileReorg(indexer, adapter);
  const remoteHead = await adapter.getHeadBlockNumber();
  const safeHead = Math.max(-1, remoteHead - confirmationDepth);
  const first = indexer.headBlock()?.number !== undefined
    ? indexer.headBlock()!.number + 1
    : manifest.deploymentBlock;
  const batchEnd = first > safeHead
    ? safeHead
    : Math.min(safeHead, first + maxBlocksPerSync - 1);
  let appliedBlocks = 0;

  for (let number = first; number <= batchEnd; number += 1) {
    const block = await adapter.getBlock(number);
    const events = await adapter.getEvents(block, manifest);
    indexer.applyBlock(block, events);
    appliedBlocks += 1;
  }

  const now = adapter.getTimestamp
    ? await adapter.getTimestamp()
    : BigInt(Math.floor(Date.now() / 1000));
  const markTicks = await adapter.getMarkTicks(manifest);
  const accounts = knownOperatorAccounts(indexer.state);
  if (manifest.portfolio && !adapter.getPortfolioHealth) {
    throw new Error("portfolio operator requires getPortfolioHealth adapter support");
  }
  const portfolioHealth =
    manifest.portfolio
      ? await adapter.getPortfolioHealth!(accounts, manifest)
      : undefined;
  const tasks = planKeeperTasks(indexer.state, {
    now,
    markTicks,
    ...(portfolioHealth ? { portfolioHealth } : {}),
  });

  return {
    fromBlock: first,
    toBlock: batchEnd,
    remoteHead,
    safeHead,
    appliedBlocks,
    ...(rolledBackTo !== undefined ? { rolledBackTo } : {}),
    tasks,
  };
}

export async function executeKeeperTasks(
  tasks: readonly KeeperTask[],
  executor: KeeperExecutor,
): Promise<{ task: KeeperTask; transactionId: string }[]> {
  const submitted: { task: KeeperTask; transactionId: string }[] = [];
  for (const task of tasks) {
    if (!await executor.simulate(task)) continue;
    submitted.push({ task, transactionId: await executor.submit(task) });
  }
  return submitted;
}

function keeperTaskPayload(task: KeeperTask): string {
  switch (task.kind) {
    case "liquidationCandidate":
      return [
        task.kind,
        task.account.toLowerCase(),
        [...task.knownMakerKeys].sort().join(","),
        [...task.conditionalIds].map(String).sort().join(","),
        [...task.trailingIds].map(String).sort().join(","),
      ].join(":");
    default:
      return [task.kind, task.marketId, task.orderId.toString()].join(":");
  }
}

export function keeperTaskId(
  manifestInput: unknown,
  head: BlockRef | undefined,
  task: KeeperTask,
): string {
  const manifest = validateOperatorManifest(manifestInput);
  const headKey = head ? `${head.number}:${head.hash.toLowerCase()}` : "uninitialized";
  return `${operatorManifestIdentity(manifest)}|${headKey}|${keeperTaskPayload(task)}`;
}

export async function executeKeeperTasksIdempotent(
  manifestInput: unknown,
  head: BlockRef | undefined,
  tasks: readonly KeeperTask[],
  executor: IdempotentKeeperExecutor,
): Promise<{ task: KeeperTask; transactionId: string; idempotencyKey: string }[]> {
  const submitted: { task: KeeperTask; transactionId: string; idempotencyKey: string }[] = [];
  for (const task of tasks) {
    const idempotencyKey = keeperTaskId(manifestInput, head, task);
    if (await executor.alreadySubmitted(idempotencyKey)) continue;
    if (!await executor.simulate(task)) continue;
    submitted.push({
      task,
      idempotencyKey,
      transactionId: await executor.submit(task, idempotencyKey),
    });
  }
  return submitted;
}

export async function runOperatorCycle(
  manifestInput: unknown,
  indexer: ReferenceIndexer,
  adapter: OperatorRpcAdapter,
  store: OperatorCheckpointStore,
  executor?: IdempotentKeeperExecutor,
  options: OperatorSyncOptions = {},
): Promise<OperatorCycleResult> {
  const manifest = validateOperatorManifest(manifestInput);
  const identity = operatorManifestIdentity(manifest);
  let restoredCheckpoint = false;

  if (!indexer.headBlock()) {
    const checkpoint = await store.load(identity);
    if (checkpoint) {
      indexer.restoreCheckpoint(checkpoint, manifest);
      restoredCheckpoint = true;
    }
  }

  const result = await syncOperatorOnce(manifest, indexer, adapter, options);
  await store.save(identity, indexer.checkpoint(manifest));

  const submitted = executor
    ? await executeKeeperTasksIdempotent(
        manifest,
        indexer.headBlock(),
        result.tasks,
        executor,
      )
    : [];

  return { ...result, restoredCheckpoint, submitted };
}

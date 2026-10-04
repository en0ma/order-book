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

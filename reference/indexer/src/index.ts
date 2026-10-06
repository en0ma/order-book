export type Address = `0x${string}`;
export type Side = 0 | 1;

export interface DeploymentManifest {
  schemaVersion: 1;
  chainId: number;
  deploymentBlock: number;
  packageVersion: string;
  collateral: { token: Address; decimals: number };
  portfolio?: { coordinator: Address; policy: Address; vault: Address };
  markets: MarketManifest[];
}

export interface MarketManifest {
  id: string;
  core: Address;
  advanced: Address;
  marketMaker?: Address;
  liquidation?: Address;
  portfolioLiquidation?: Address;
  integrationLens?: Address;
  oracle: Address;
  portfolioMarketIndex?: number;
  scales: { collateralUnitsPerLotTick: string };
  parameters: {
    executionBandTicks: number;
    initialMarginBps: number;
    maintenanceMarginBps?: number;
    takerFeeBps: number;
    makerRebateBps: number;
    oracleMaxAgeSeconds?: number;
  };
}

export interface BlockCursor {
  number: number;
  hash: string;
}

export interface IndexedBlock {
  chainId: number;
  number: number;
  hash: string;
  parentHash: string;
  logs: readonly ProtocolLog[];
}

export interface ProtocolLog {
  blockNumber: number;
  blockHash: string;
  transactionIndex: number;
  logIndex: number;
  address: Address;
  event: DecodedProtocolEvent;
}

export type DecodedProtocolEvent =
  | { name: "LiquidityAdded"; maker: Address; side: Side; tick: number; lots: bigint; generation: number }
  | { name: "LiquidityRemoved"; maker: Address; side: Side; tick: number; lots: bigint; generation: number }
  | { name: "Trade"; taker: Address; takerSide: Side; tick: number; lots: bigint }
  | { name: "ConditionalOrderPlaced"; orderId: bigint; owner: Address; side: Side; triggerTick: number; triggerAboveOrEqual: boolean }
  | { name: "ConditionalExpirySet"; orderId: bigint; expiry: bigint }
  | { name: "ConditionalOrderCancelled"; orderId: bigint }
  | { name: "ConditionalOrderExpired"; orderId: bigint }
  | { name: "ConditionalOrderExecuted"; orderId: bigint }
  | { name: "RestingOrderLinked"; orderId: bigint }
  | { name: "RestingOrderSynced"; orderId: bigint; remainingLots: bigint }
  | { name: "RestingOrderCancelled"; orderId: bigint }
  | { name: "TrailingOrderPlaced"; orderId: bigint; owner: Address; side: Side }
  | { name: "TrailingExpirySet"; orderId: bigint; expiry: bigint }
  | { name: "TrailingOrderCancelled"; orderId: bigint }
  | { name: "TrailingOrderExpired"; orderId: bigint }
  | { name: "TrailingOrderExecuted"; orderId: bigint }
  | { name: "OCOLinked"; firstOrderId: bigint; secondOrderId: bigint }
  | { name: "OTOLinked"; parentOrderId: bigint; childOrderId: bigint }
  | { name: "OTOActivated"; parentOrderId: bigint; childOrderId: bigint; lots: bigint }
  | { name: "OTOResized"; parentOrderId: bigint; childOrderId: bigint; lots: bigint }
  | { name: "ManagedQuoteUpdated"; maker: Address; side: Side; tick: number; shares: bigint; generation: number }
  | { name: "ManagedQuoteRemoved"; maker: Address; side: Side; tick: number }
  | { name: "PortfolioLockSynchronized"; account: Address; equity: bigint; requirement: bigint; lockedCollateral: bigint };

export interface PoolState {
  remainingLots: string;
  generation: number;
}

export interface AdvancedOrderState {
  active: boolean;
  dormant: boolean;
  expiry: string;
  resting: boolean;
  sibling?: string;
  parent?: string;
  children?: string[];
}

export interface ManagedQuoteState {
  shares: string;
  generation: number;
}

export interface PortfolioLockState {
  equity: string;
  requirement: string;
  lockedCollateral: string;
}

export interface IndexerState {
  pools: Record<string, PoolState>;
  conditionals: Record<string, AdvancedOrderState>;
  trailing: Record<string, AdvancedOrderState>;
  managedQuotes: Record<string, ManagedQuoteState>;
  portfolioLocks: Record<string, PortfolioLockState>;
}

export interface IndexerCheckpoint {
  chainId: number;
  deploymentBlock: number;
  cursor?: BlockCursor;
  state: IndexerState;
  retainedHistory?: Snapshot[];
}

export interface Snapshot {
  cursor?: BlockCursor;
  state: IndexerState;
}

export class IndexerError extends Error {}

function emptyState(): IndexerState {
  return {
    pools: {},
    conditionals: {},
    trailing: {},
    managedQuotes: {},
    portfolioLocks: {},
  };
}

function cloneState(state: IndexerState): IndexerState {
  return structuredClone(state);
}

function lower(address: string): string {
  return address.toLowerCase();
}

function poolKey(marketId: string, side: Side, tick: number): string {
  return `${marketId}:${side}:${tick}`;
}

function orderKey(marketId: string, orderId: bigint): string {
  return `${marketId}:${orderId.toString()}`;
}

function managedQuoteKey(
  marketId: string,
  maker: Address,
  side: Side,
  tick: number,
): string {
  return `${marketId}:${lower(maker)}:${side}:${tick}`;
}

function canonicalLogs(logs: readonly ProtocolLog[]): ProtocolLog[] {
  const ordered = [...logs].sort((a, b) =>
    a.transactionIndex - b.transactionIndex || a.logIndex - b.logIndex
  );

  for (let i = 1; i < ordered.length; i += 1) {
    const prior = ordered[i - 1];
    const next = ordered[i];
    if (
      prior.transactionIndex === next.transactionIndex
      && prior.logIndex === next.logIndex
      && (
        prior.blockHash !== next.blockHash
        || lower(prior.address) !== lower(next.address)
        || prior.event.name !== next.event.name
      )
    ) {
      throw new IndexerError("conflicting logs share the same transaction/log position");
    }
  }

  return ordered;
}

export class ReferenceIndexer {
  readonly manifest: DeploymentManifest;
  readonly maxReorgDepth: number;

  private readonly coreMarket = new Map<string, string>();
  private readonly advancedMarket = new Map<string, string>();
  private readonly mmMarket = new Map<string, string>();
  private coordinator?: string;

  private cursor?: BlockCursor;
  private state: IndexerState;
  private history: Snapshot[];

  constructor(
    manifest: DeploymentManifest,
    options: { maxReorgDepth?: number; checkpoint?: IndexerCheckpoint } = {},
  ) {
    if (manifest.schemaVersion !== 1) throw new IndexerError("unsupported manifest schema");
    if (!Number.isInteger(manifest.chainId) || manifest.chainId <= 0) {
      throw new IndexerError("invalid manifest chainId");
    }
    if (!Number.isInteger(manifest.deploymentBlock) || manifest.deploymentBlock < 0) {
      throw new IndexerError("invalid deploymentBlock");
    }
    if (manifest.markets.length === 0) throw new IndexerError("manifest has no markets");

    this.manifest = manifest;
    this.maxReorgDepth = options.maxReorgDepth ?? 64;
    if (!Number.isInteger(this.maxReorgDepth) || this.maxReorgDepth < 1) {
      throw new IndexerError("maxReorgDepth must be a positive integer");
    }

    for (const market of manifest.markets) {
      if (!market.id) throw new IndexerError("market id is required");
      this.bind(this.coreMarket, market.core, market.id, "core");
      this.bind(this.advancedMarket, market.advanced, market.id, "advanced");
      if (market.marketMaker) {
        this.bind(this.mmMarket, market.marketMaker, market.id, "marketMaker");
      }
    }
    if (manifest.portfolio) this.coordinator = lower(manifest.portfolio.coordinator);

    if (options.checkpoint) {
      const checkpoint = options.checkpoint;
      if (
        checkpoint.chainId !== manifest.chainId
        || checkpoint.deploymentBlock !== manifest.deploymentBlock
      ) {
        throw new IndexerError("checkpoint does not match deployment");
      }
      this.cursor = checkpoint.cursor ? { ...checkpoint.cursor } : undefined;
      this.state = cloneState(checkpoint.state);

      const retained = checkpoint.retainedHistory ?? [];
      this.history = retained.map((snapshot) => ({
        cursor: snapshot.cursor ? { ...snapshot.cursor } : undefined,
        state: cloneState(snapshot.state),
      }));
      if (this.history.length === 0) {
        this.history = [this.snapshot()];
      } else {
        const latest = this.history[this.history.length - 1];
        if (
          latest.cursor?.number !== this.cursor?.number
          || latest.cursor?.hash !== this.cursor?.hash
        ) {
          throw new IndexerError("checkpoint retained history does not end at cursor");
        }
        if (this.history.length > this.maxReorgDepth + 1) {
          this.history = this.history.slice(-(this.maxReorgDepth + 1));
        }
      }
    } else {
      this.state = emptyState();
      this.history = [this.snapshot()];
    }
  }

  head(): BlockCursor | undefined {
    return this.cursor ? { ...this.cursor } : undefined;
  }

  retainedBlocks(): BlockCursor[] {
    return this.history
      .flatMap((snapshot) => snapshot.cursor ? [{ ...snapshot.cursor }] : []);
  }

  rollbackTo(cursor?: BlockCursor): void {
    if (!cursor) {
      const initial = this.history[0];
      if (initial.cursor) {
        throw new IndexerError("cannot rollback before checkpoint");
      }
      this.restore(initial);
      this.history = [this.snapshot()];
      return;
    }

    const index = this.history.findIndex(
      (snapshot) =>
        snapshot.cursor?.number === cursor.number
        && snapshot.cursor.hash === cursor.hash,
    );
    if (index < 0) throw new IndexerError("rollback checkpoint unavailable");

    this.restore(this.history[index]);
    this.history = this.history.slice(0, index + 1);
  }

  snapshotState(): IndexerState {
    return cloneState(this.state);
  }

  checkpoint(): IndexerCheckpoint {
    return {
      chainId: this.manifest.chainId,
      deploymentBlock: this.manifest.deploymentBlock,
      cursor: this.cursor ? { ...this.cursor } : undefined,
      state: cloneState(this.state),
      retainedHistory: this.history.map((snapshot) => ({
        cursor: snapshot.cursor ? { ...snapshot.cursor } : undefined,
        state: cloneState(snapshot.state),
      })),
    };
  }

  applyBlock(block: IndexedBlock): void {
    if (block.chainId !== this.manifest.chainId) {
      throw new IndexerError("block chainId does not match manifest");
    }
    if (block.number < this.manifest.deploymentBlock) return;

    for (const snapshot of this.history) {
      if (
        snapshot.cursor?.number === block.number
        && snapshot.cursor.hash === block.hash
      ) {
        return;
      }
    }

    if (!this.cursor && block.number !== this.manifest.deploymentBlock) {
      throw new IndexerError("first block must equal deploymentBlock");
    }

    const before = this.snapshot();
    const historyBefore = this.history.slice();

    try {
      this.reconcileParent(block);

      if (this.cursor && block.number !== this.cursor.number + 1) {
        throw new IndexerError("non-contiguous block");
      }

      const blockLogIds = new Set<string>();
      for (const log of canonicalLogs(block.logs)) {
        if (log.blockNumber !== block.number || log.blockHash !== block.hash) {
          throw new IndexerError("log does not belong to supplied block");
        }

        const logId = `${block.hash}:${log.transactionIndex}:${log.logIndex}`;
        if (blockLogIds.has(logId)) continue;
        this.applyLog(log);
        blockLogIds.add(logId);
      }

      this.cursor = { number: block.number, hash: block.hash };
      this.history.push(this.snapshot());
      if (this.history.length > this.maxReorgDepth + 1) this.history.shift();
    } catch (error) {
      this.restore(before);
      this.history = historyBefore;
      throw error;
    }
  }

  private reconcileParent(block: IndexedBlock): void {
    if (!this.cursor) return;
    if (block.number === this.cursor.number + 1 && block.parentHash === this.cursor.hash) {
      return;
    }

    let ancestorIndex = -1;
    for (let i = this.history.length - 1; i >= 0; i -= 1) {
      if (this.history[i].cursor?.hash === block.parentHash) {
        ancestorIndex = i;
        break;
      }
    }
    if (ancestorIndex < 0) {
      throw new IndexerError("reorg exceeds retained history");
    }

    this.restore(this.history[ancestorIndex]);
    this.history = this.history.slice(0, ancestorIndex + 1);
  }

  private applyLog(log: ProtocolLog): void {
    const address = lower(log.address);
    const event = log.event;

    if (
      event.name === "LiquidityAdded"
      || event.name === "LiquidityRemoved"
      || event.name === "Trade"
    ) {
      const marketId = this.requireMarket(this.coreMarket, address, event.name);
      this.applyCoreEvent(marketId, event);
      return;
    }

    if (
      event.name === "ConditionalOrderPlaced"
      || event.name === "ConditionalExpirySet"
      || event.name === "ConditionalOrderCancelled"
      || event.name === "ConditionalOrderExpired"
      || event.name === "ConditionalOrderExecuted"
      || event.name === "RestingOrderLinked"
      || event.name === "RestingOrderSynced"
      || event.name === "RestingOrderCancelled"
      || event.name === "TrailingOrderPlaced"
      || event.name === "TrailingExpirySet"
      || event.name === "TrailingOrderCancelled"
      || event.name === "TrailingOrderExpired"
      || event.name === "TrailingOrderExecuted"
      || event.name === "OCOLinked"
      || event.name === "OTOLinked"
      || event.name === "OTOActivated"
      || event.name === "OTOResized"
    ) {
      const marketId = this.requireMarket(this.advancedMarket, address, event.name);
      this.applyAdvancedEvent(marketId, event);
      return;
    }

    if (event.name === "ManagedQuoteUpdated" || event.name === "ManagedQuoteRemoved") {
      const marketId = this.requireMarket(this.mmMarket, address, event.name);
      const key = managedQuoteKey(marketId, event.maker, event.side, event.tick);
      if (event.name === "ManagedQuoteUpdated") {
        this.state.managedQuotes[key] = {
          shares: event.shares.toString(),
          generation: event.generation,
        };
      } else {
        delete this.state.managedQuotes[key];
      }
      return;
    }

    if (event.name === "PortfolioLockSynchronized") {
      if (!this.coordinator || address !== this.coordinator) {
        throw new IndexerError("portfolio lock event came from unexpected address");
      }
      this.state.portfolioLocks[lower(event.account)] = {
        equity: event.equity.toString(),
        requirement: event.requirement.toString(),
        lockedCollateral: event.lockedCollateral.toString(),
      };
    }
  }

  private applyCoreEvent(
    marketId: string,
    event: Extract<
      DecodedProtocolEvent,
      { name: "LiquidityAdded" | "LiquidityRemoved" | "Trade" }
    >,
  ): void {
    if (event.name === "Trade") {
      const makerSide: Side = event.takerSide === 0 ? 1 : 0;
      const key = poolKey(marketId, makerSide, event.tick);
      const current = this.state.pools[key] ?? { remainingLots: "0", generation: 0 };
      const remaining = BigInt(current.remainingLots) - event.lots;
      if (remaining < 0n) throw new IndexerError("trade exceeds replayed pool lots");
      this.state.pools[key] = {
        remainingLots: remaining.toString(),
        generation: remaining === 0n ? current.generation + 1 : current.generation,
      };
      return;
    }

    const key = poolKey(marketId, event.side, event.tick);
    const current = this.state.pools[key] ?? { remainingLots: "0", generation: 0 };
    const currentLots = BigInt(current.remainingLots);

    if (event.name === "LiquidityAdded") {
      this.state.pools[key] = {
        remainingLots: (currentLots + event.lots).toString(),
        generation: event.generation,
      };
      return;
    }

    const remaining = currentLots - event.lots;
    if (remaining < 0n) throw new IndexerError("liquidity removal exceeds replayed pool lots");
    this.state.pools[key] = {
      remainingLots: remaining.toString(),
      generation: event.generation,
    };
  }

  private applyAdvancedEvent(
    marketId: string,
    event: Exclude<
      DecodedProtocolEvent,
      | { name: "LiquidityAdded" }
      | { name: "LiquidityRemoved" }
      | { name: "Trade" }
      | { name: "ManagedQuoteUpdated" }
      | { name: "ManagedQuoteRemoved" }
      | { name: "PortfolioLockSynchronized" }
    >,
  ): void {
    if (event.name === "OCOLinked") {
      const first = this.ensureConditional(marketId, event.firstOrderId);
      const second = this.ensureConditional(marketId, event.secondOrderId);
      first.sibling = event.secondOrderId.toString();
      second.sibling = event.firstOrderId.toString();
      return;
    }

    if (event.name === "OTOLinked") {
      const parent = this.ensureConditional(marketId, event.parentOrderId);
      const child = this.ensureConditional(marketId, event.childOrderId);
      parent.children = [...new Set([...(parent.children ?? []), event.childOrderId.toString()])];
      child.parent = event.parentOrderId.toString();
      child.active = false;
      child.dormant = true;
      return;
    }

    if (event.name === "OTOActivated" || event.name === "OTOResized") {
      const child = this.ensureConditional(marketId, event.childOrderId);
      child.parent = event.parentOrderId.toString();
      if (event.name === "OTOActivated") {
        child.active = true;
        child.dormant = false;
      }
      return;
    }

    const isTrailing = event.name.startsWith("Trailing");
    const key = orderKey(marketId, event.orderId);
    const collection = isTrailing ? this.state.trailing : this.state.conditionals;
    const state = collection[key] ?? {
      active: false,
      dormant: false,
      expiry: "0",
      resting: false,
    };

    if (event.name === "ConditionalOrderPlaced" || event.name === "TrailingOrderPlaced") {
      state.active = true;
      state.dormant = false;
      state.resting = false;
    } else if (event.name === "ConditionalExpirySet" || event.name === "TrailingExpirySet") {
      state.expiry = event.expiry.toString();
    } else if (event.name === "RestingOrderLinked") {
      state.resting = true;
    } else if (event.name === "RestingOrderSynced") {
      if (event.remainingLots === 0n) {
        state.resting = false;
        state.expiry = "0";
      }
    } else if (event.name === "RestingOrderCancelled") {
      state.resting = false;
      state.expiry = "0";
    } else if (
      event.name === "ConditionalOrderCancelled"
      || event.name === "ConditionalOrderExpired"
      || event.name === "TrailingOrderCancelled"
      || event.name === "TrailingOrderExpired"
      || event.name === "TrailingOrderExecuted"
    ) {
      state.active = false;
      state.dormant = false;
      state.resting = false;
      state.expiry = "0";
    } else if (event.name === "ConditionalOrderExecuted") {
      state.active = false;
      state.dormant = false;
      if (!state.resting) state.expiry = "0";
    }

    collection[key] = state;
  }

  private ensureConditional(marketId: string, orderId: bigint): AdvancedOrderState {
    const key = orderKey(marketId, orderId);
    this.state.conditionals[key] ??= {
      active: false,
      dormant: false,
      expiry: "0",
      resting: false,
    };
    return this.state.conditionals[key];
  }

  private requireMarket(
    table: Map<string, string>,
    address: string,
    eventName: string,
  ): string {
    const marketId = table.get(address);
    if (!marketId) {
      throw new IndexerError(`${eventName} came from an unexpected contract`);
    }
    return marketId;
  }

  private bind(
    table: Map<string, string>,
    address: Address,
    marketId: string,
    role: string,
  ): void {
    const key = lower(address);
    if (table.has(key)) throw new IndexerError(`duplicate ${role} address in manifest`);
    table.set(key, marketId);
  }

  private snapshot(): Snapshot {
    return {
      cursor: this.cursor ? { ...this.cursor } : undefined,
      state: cloneState(this.state),
    };
  }

  private restore(snapshot: Snapshot): void {
    this.cursor = snapshot.cursor ? { ...snapshot.cursor } : undefined;
    this.state = cloneState(snapshot.state);
  }
}

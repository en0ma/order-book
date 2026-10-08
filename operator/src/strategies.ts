import type { Address, NormalizedEvent } from "./index.js";

export type StrategyKind = "iceberg" | "twap" | "pegged";
export interface StrategyRecord {
  marketId: string;
  strategyId: bigint;
  owner: Address;
  kind: StrategyKind;
  placedAtBlock: number;
  // Placement parameters are immutable. Execution progress must be read from chain.
  totalLots: bigint;
  sliceLots?: bigint;
  tick?: number;
  limitTick?: number;
  startTime?: bigint;
  interval?: bigint;
  deadline?: bigint;
  offsetTicks?: number;
  priceBoundTick?: number;
}
export interface StrategyObservation {
  active: boolean;
  remainingLots: bigint;
  visibleLots: bigint;
  nextExecution: bigint;
  currentTick: number;
}
export type StrategyTask =
  | { kind: "refreshIceberg"; marketId: string; strategyId: bigint }
  | { kind: "executeTWAPSlice"; marketId: string; strategyId: bigint }
  | { kind: "syncPegged"; marketId: string; strategyId: bigint };
export interface StrategySnapshot {
  version: 1;
  records: {
    key: string;
    marketId: string;
    strategyId: string;
    owner: Address;
    kind: StrategyKind;
    placedAtBlock: number;
    totalLots: string;
    sliceLots?: string;
    tick?: number;
    limitTick?: number;
    startTime?: string;
    interval?: string;
    deadline?: string;
    offsetTicks?: number;
    priceBoundTick?: number;
  }[];
}
const keyOf = (marketId: string, id: bigint) => JSON.stringify([marketId, id.toString()]);
function uint(value: unknown, name: string): bigint {
  const n = typeof value === "bigint" ? value :
    (typeof value === "number" && Number.isSafeInteger(value) ? BigInt(value) :
      (typeof value === "string" && /^\\d+$/.test(value) ? BigInt(value) : -1n));
  if (n < 0n) throw new TypeError(name + " must be a nonnegative integer");
  return n;
}
function numeric(value: unknown, name: string): number {
  const n = Number(uint(value, name));
  if (!Number.isSafeInteger(n)) throw new TypeError(name + " exceeds safe integer");
  return n;
}
function owner(value: unknown): Address {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new TypeError("invalid strategy owner");
  }
  return value as Address;
}

/** Replay canonical, ordered strategy events. Never infer fills or due slices from placement events. */
export class StrategyRegistry {
  readonly records = new Map<string, StrategyRecord>();

  apply(event: NormalizedEvent): void {
    const names = ["IcebergPlaced", "TWAPPlaced", "PeggedPlaced", "StrategyCancelled", "StrategyCompleted"];
    if (!names.includes(event.name)) return;
    if (!event.marketId) throw new TypeError("strategy event missing market");
    const a = event.args;
    const strategyId = uint(a.strategyId, "strategyId");
    const key = keyOf(event.marketId, strategyId);
    if (event.name === "StrategyCancelled" || event.name === "StrategyCompleted") {
      this.records.delete(key);
      return;
    }
    if (this.records.has(key)) throw new Error("duplicate active strategy id");
    const common = {
      marketId: event.marketId,
      strategyId,
      owner: owner(a.owner),
      placedAtBlock: event.blockNumber,
    };
    let next: StrategyRecord;
    switch (event.name) {
      case "IcebergPlaced":
        next = { ...common, kind: "iceberg", tick: numeric(a.tick, "tick"),
          totalLots: uint(a.totalLots, "totalLots"), sliceLots: uint(a.displayLots, "displayLots") };
        break;
      case "TWAPPlaced":
        next = { ...common, kind: "twap", limitTick: numeric(a.limitTick, "limitTick"),
          totalLots: uint(a.totalLots, "totalLots"), sliceLots: uint(a.sliceLots, "sliceLots"),
          startTime: uint(a.startTime, "startTime"), interval: uint(a.interval, "interval"),
          deadline: uint(a.deadline, "deadline") };
        break;
      default:
        next = { ...common, kind: "pegged", totalLots: uint(a.lots, "lots"),
          tick: numeric(a.initialTick, "initialTick"),
          offsetTicks: Number(a.offsetTicks), priceBoundTick: numeric(a.priceBoundTick, "priceBoundTick") };
        if (!Number.isInteger(next.offsetTicks) || next.offsetTicks < -32768 || next.offsetTicks > 32767) {
          throw new TypeError("invalid pegged offset");
        }
    }
    this.records.set(key, next);
  }

  applyBatch(events: readonly NormalizedEvent[]): void {
    const original = new Map(this.records);
    try {
      for (const event of events) this.apply(event);
    } catch (error) {
      this.records.clear();
      for (const [key, value] of original) this.records.set(key, value);
      throw error;
    }
  }

  snapshot(): StrategySnapshot {
    return { version: 1, records: [...this.records.entries()].sort(([a], [b]) => a.localeCompare(b))
      .map(([key, r]) => ({
        key, marketId: r.marketId, strategyId: r.strategyId.toString(), owner: r.owner,
        kind: r.kind, placedAtBlock: r.placedAtBlock, totalLots: r.totalLots.toString(),
        ...(r.sliceLots === undefined ? {} : { sliceLots: r.sliceLots.toString() }),
        ...(r.tick === undefined ? {} : { tick: r.tick }),
        ...(r.limitTick === undefined ? {} : { limitTick: r.limitTick }),
        ...(r.startTime === undefined ? {} : { startTime: r.startTime.toString() }),
        ...(r.interval === undefined ? {} : { interval: r.interval.toString() }),
        ...(r.deadline === undefined ? {} : { deadline: r.deadline.toString() }),
        ...(r.offsetTicks === undefined ? {} : { offsetTicks: r.offsetTicks }),
        ...(r.priceBoundTick === undefined ? {} : { priceBoundTick: r.priceBoundTick }),
      })) };
  }

  restore(snapshot: StrategySnapshot): void {
    if (snapshot.version !== 1 || !Array.isArray(snapshot.records)) throw new TypeError("invalid strategy snapshot");
    const next = new Map<string, StrategyRecord>();
    for (const r of snapshot.records) {
      const strategyId = uint(r.strategyId, "strategyId");
      const key = keyOf(r.marketId, strategyId);
      if (key !== r.key || next.has(key)) throw new Error("invalid or duplicate strategy snapshot key");
      next.set(key, {
        marketId: r.marketId, strategyId, owner: owner(r.owner), kind: r.kind,
        placedAtBlock: numeric(r.placedAtBlock, "placedAtBlock"), totalLots: uint(r.totalLots, "totalLots"),
        ...(r.sliceLots === undefined ? {} : { sliceLots: uint(r.sliceLots, "sliceLots") }),
        ...(r.tick === undefined ? {} : { tick: numeric(r.tick, "tick") }),
        ...(r.limitTick === undefined ? {} : { limitTick: numeric(r.limitTick, "limitTick") }),
        ...(r.startTime === undefined ? {} : { startTime: uint(r.startTime, "startTime") }),
        ...(r.interval === undefined ? {} : { interval: uint(r.interval, "interval") }),
        ...(r.deadline === undefined ? {} : { deadline: uint(r.deadline, "deadline") }),
        ...(r.offsetTicks === undefined ? {} : { offsetTicks: r.offsetTicks }),
        ...(r.priceBoundTick === undefined ? {} : { priceBoundTick: numeric(r.priceBoundTick, "priceBoundTick") }),
      });
    }
    this.records.clear();
    for (const [key, r] of next) this.records.set(key, r);
  }
}

/** Only plan keeper calls from live, authoritative strategy observations; events alone are insufficient. */
export function planStrategyTasks(
  registry: StrategyRegistry,
  observations: ReadonlyMap<string, StrategyObservation>,
  now: bigint,
  markTicks: Readonly<Record<string, number>>,
): StrategyTask[] {
  const tasks: StrategyTask[] = [];
  for (const [key, record] of [...registry.records.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const s = observations.get(key);
    if (!s || !s.active || s.remainingLots <= 0n) continue;
    if (record.kind === "iceberg" && s.visibleLots === 0n) {
      tasks.push({ kind: "refreshIceberg", marketId: record.marketId, strategyId: record.strategyId });
    } else if (record.kind === "twap" && now >= s.nextExecution
      && (record.deadline === undefined || now <= record.deadline)) {
      tasks.push({ kind: "executeTWAPSlice", marketId: record.marketId, strategyId: record.strategyId });
    } else if (record.kind === "pegged") {
      const mark = markTicks[record.marketId];
      if (mark === undefined || record.offsetTicks === undefined) continue;
      const raw = mark + record.offsetTicks;
      if (raw < 0 || raw > 65535 || raw === s.currentTick) continue;
      // Contract enforces bid/ask bounds; simulation remains mandatory before submission.
      tasks.push({ kind: "syncPegged", marketId: record.marketId, strategyId: record.strategyId });
    }
  }
  return tasks;
}

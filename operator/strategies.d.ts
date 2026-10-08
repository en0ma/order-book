import type { Address, NormalizedEvent } from "./index.js";
export type StrategyKind = "iceberg" | "twap" | "pegged";
export interface StrategyRecord {
  marketId: string; strategyId: bigint; owner: Address; kind: StrategyKind;
  placedAtBlock: number; totalLots: bigint; sliceLots?: bigint; tick?: number;
  limitTick?: number; startTime?: bigint; interval?: bigint; deadline?: bigint;
  offsetTicks?: number; priceBoundTick?: number;
}
export interface StrategyObservation {
  active: boolean; remainingLots: bigint; visibleLots: bigint;
  nextExecution: bigint; currentTick: number;
}
export type StrategyTask =
  | { kind: "refreshIceberg"; marketId: string; strategyId: bigint }
  | { kind: "executeTWAPSlice"; marketId: string; strategyId: bigint }
  | { kind: "syncPegged"; marketId: string; strategyId: bigint };
export interface StrategySnapshot {
  version: 1;
  records: {
    key: string; marketId: string; strategyId: string; owner: Address;
    kind: StrategyKind; placedAtBlock: number; totalLots: string;
    sliceLots?: string; tick?: number; limitTick?: number; startTime?: string;
    interval?: string; deadline?: string; offsetTicks?: number; priceBoundTick?: number;
  }[];
}
export declare class StrategyRegistry {
  readonly records: Map<string, StrategyRecord>;
  apply(event: NormalizedEvent): void;
  applyBatch(events: readonly NormalizedEvent[]): void;
  snapshot(): StrategySnapshot;
  restore(snapshot: StrategySnapshot): void;
}
export declare function planStrategyTasks(
  registry: StrategyRegistry,
  observations: ReadonlyMap<string, StrategyObservation>,
  now: bigint,
  markTicks: Readonly<Record<string, number>>,
): StrategyTask[];

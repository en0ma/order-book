import type { Address, NormalizedEvent, OperatorManifest } from "./index.js";
export type CanonicalDecodedEvent =
  | { name: "LiquidityAdded"; maker: Address; side: 0 | 1; tick: number; lots: bigint; generation: number }
  | { name: "LiquidityRemoved"; maker: Address; side: 0 | 1; tick: number; lots: bigint; generation: number }
  | { name: "Trade"; taker: Address; takerSide: 0 | 1; tick: number; lots: bigint }
  | { name: "ConditionalOrderPlaced"; orderId: bigint; owner: Address; side: 0 | 1; triggerTick: number; triggerAboveOrEqual: boolean }
  | { name: "ConditionalExpirySet"; orderId: bigint; expiry: bigint }
  | { name: "ConditionalOrderCancelled"; orderId: bigint }
  | { name: "ConditionalOrderExpired"; orderId: bigint }
  | { name: "ConditionalOrderExecuted"; orderId: bigint }
  | { name: "RestingOrderLinked"; orderId: bigint }
  | { name: "RestingOrderSynced"; orderId: bigint; remainingLots: bigint }
  | { name: "RestingOrderCancelled"; orderId: bigint }
  | { name: "TrailingOrderPlaced"; orderId: bigint; owner: Address; side: 0 | 1 }
  | { name: "TrailingExpirySet"; orderId: bigint; expiry: bigint }
  | { name: "TrailingOrderCancelled"; orderId: bigint }
  | { name: "TrailingOrderExpired"; orderId: bigint }
  | { name: "TrailingOrderExecuted"; orderId: bigint }
  | { name: "OCOLinked"; firstOrderId: bigint; secondOrderId: bigint }
  | { name: "OTOLinked"; parentOrderId: bigint; childOrderId: bigint }
  | { name: "OTOActivated"; parentOrderId: bigint; childOrderId: bigint; lots: bigint }
  | { name: "OTOResized"; parentOrderId: bigint; childOrderId: bigint; lots: bigint }
  | { name: "ManagedQuoteUpdated"; maker: Address; side: 0 | 1; tick: number; shares: bigint; generation: number }
  | { name: "ManagedQuoteRemoved"; maker: Address; side: 0 | 1; tick: number }
  | { name: "IcebergPlaced"; strategyId: bigint; owner: Address; side: 0 | 1; tick: number; totalLots: bigint; displayLots: bigint }
  | { name: "TWAPPlaced"; strategyId: bigint; owner: Address; side: 0 | 1; limitTick: number; totalLots: bigint; sliceLots: bigint; startTime: bigint; interval: bigint; deadline: bigint }
  | { name: "PeggedPlaced"; strategyId: bigint; owner: Address; side: 0 | 1; offsetTicks: number; priceBoundTick: number; lots: bigint; initialTick: number }
  | { name: "StrategyCancelled"; strategyId: bigint; remainingLots: bigint }
  | { name: "StrategyCompleted"; strategyId: bigint }
  | { name: "PortfolioLockSynchronized"; account: Address; equity: bigint; requirement: bigint; lockedCollateral: bigint };
export interface CanonicalLogEnvelope {
  chainId: number; blockNumber: number; blockHash: string; transactionIndex: number; logIndex: number; address: Address; event: CanonicalDecodedEvent;
}
export declare function normalizeCanonicalEvent(manifestInput: unknown, envelope: CanonicalLogEnvelope): NormalizedEvent;
export declare function normalizeCanonicalEvents(manifestInput: unknown, envelopes: readonly CanonicalLogEnvelope[]): NormalizedEvent[];

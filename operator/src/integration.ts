import {
  type Address,
  type NormalizedEvent,
  type OperatorManifest,
  validateOperatorManifest,
} from "./index.js";

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
  | { name: "PortfolioLockSynchronized"; account: Address; equity: bigint; requirement: bigint; lockedCollateral: bigint };

export interface CanonicalLogEnvelope {
  chainId: number;
  blockNumber: number;
  blockHash: string;
  transactionIndex: number;
  logIndex: number;
  address: Address;
  event: CanonicalDecodedEvent;
}

function lower(value: string): string {
  return value.toLowerCase();
}

function marketFor(
  manifest: OperatorManifest,
  address: Address,
  eventName: string,
): string | undefined {
  const key = lower(address);

  if (eventName === "PortfolioLockSynchronized") {
    if (manifest.portfolio && lower(manifest.portfolio.coordinator) === key) return undefined;
    throw new Error("portfolio event came from unexpected address");
  }

  const role =
    eventName === "LiquidityAdded"
      || eventName === "LiquidityRemoved"
      || eventName === "Trade"
      ? "core"
      : eventName === "ManagedQuoteUpdated"
        || eventName === "ManagedQuoteRemoved"
        ? "marketMaker"
        : "advanced";

  for (const market of manifest.markets) {
    const expected =
      role === "core"
        ? market.core
        : role === "advanced"
          ? market.advanced
          : market.marketMaker;
    if (expected && lower(expected) === key) return market.id;
  }

  throw new Error(`${role} event came from unexpected address`);
}

export function normalizeCanonicalEvent(
  manifestInput: unknown,
  envelope: CanonicalLogEnvelope,
): NormalizedEvent {
  const manifest = validateOperatorManifest(manifestInput);
  if (envelope.chainId !== manifest.chainId) {
    throw new Error("event chainId does not match manifest");
  }
  const event = envelope.event;
  const marketId = marketFor(manifest, envelope.address, event.name);
  const args: Record<string, unknown> = {};

  switch (event.name) {
    case "LiquidityAdded":
    case "LiquidityRemoved":
      Object.assign(args, {
        account: event.maker,
        side: event.side,
        tick: event.tick,
        lots: event.lots,
        generation: event.generation,
      });
      break;
    case "Trade":
      Object.assign(args, { side: event.takerSide, tick: event.tick, lots: event.lots });
      break;
    case "ConditionalOrderPlaced":
      Object.assign(args, {
        orderId: event.orderId,
        owner: event.owner,
        side: event.side,
        triggerTick: event.triggerTick,
        triggerAboveOrEqual: event.triggerAboveOrEqual,
      });
      break;
    case "TrailingOrderPlaced":
      Object.assign(args, { orderId: event.orderId, owner: event.owner, side: event.side });
      break;
    case "ManagedQuoteUpdated":
      Object.assign(args, event);
      delete args.name;
      break;
    case "ManagedQuoteRemoved":
      Object.assign(args, event);
      delete args.name;
      break;
    case "PortfolioLockSynchronized":
      Object.assign(args, {
        account: event.account,
        equity: event.equity,
        requirement: event.requirement,
        lockedCollateral: event.lockedCollateral,
      });
      break;
    default:
      Object.assign(args, event);
      delete args.name;
      break;
  }

  return {
    chainId: envelope.chainId,
    blockNumber: envelope.blockNumber,
    blockHash: envelope.blockHash,
    transactionIndex: envelope.transactionIndex,
    logIndex: envelope.logIndex,
    address: envelope.address,
    ...(marketId ? { marketId } : {}),
    name: event.name,
    args,
  };
}

export function normalizeCanonicalEvents(
  manifestInput: unknown,
  envelopes: readonly CanonicalLogEnvelope[],
): NormalizedEvent[] {
  return envelopes.map((envelope) => normalizeCanonicalEvent(manifestInput, envelope));
}

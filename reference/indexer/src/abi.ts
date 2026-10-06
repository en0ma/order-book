import { IndexerError, type Address, type DecodedProtocolEvent, type DeploymentManifest } from "./index.js";
import type { Hex, RawRpcLog } from "./node.js";

type Decoder = (log: RawRpcLog) => DecodedProtocolEvent;

const TOPICS = {
  LiquidityAdded: "0x9c798c467a295a9fd60bafb069e2912455685c4eb9bc9a22ab731bfb79429cc9",
  LiquidityRemoved: "0xfc059e57cac3e3f22d5731596ff48b87a913eb4386d6771bcbc79bee5bd79fd2",
  Trade: "0x89603b21f4d1f13817a4f74328b6b6370cdc53da61fb18642259034530adb504",
  ConditionalOrderPlaced: "0x287e07f016f75e7d2f86c80a02961606d605b2e7ebba58c738a49bee89c329a5",
  ConditionalOrderCancelled: "0x3badfe7f6106f3afa5c85e49acfde5747034e0096fd449529bcb7b91cbce7ccd",
  ConditionalOrderExecuted: "0x9a58512fdfdb90178ac843f3962375e1c0b7c1cbd169aa3fe9da8e2e6fedf4d0",
  OCOLinked: "0x0aa6adf7e37731183cbf032ab2e951a3efc9915a8fd2c8e47ae36535c95e4f3e",
  OTOLinked: "0xb3bae83d2c9f6562a72ff46ce31a77233a0a248fbd280965c5e252098a2ba5c8",
  OTOActivated: "0xc1878aa07e27df7cffd1fadbcd6d7772010e222f228a747d3e95392a7775c429",
  OTOResized: "0xd443a9a7562438cb2fee22dcca32b1601eea47848a270f7f0715695949defc09",
  RestingOrderLinked: "0x5a8f2233941c364a25d9986e5be21c0a8f23346350f1ab40b0041917017df3c3",
  RestingOrderSynced: "0x3d78691f6ccace6718716b4e2bfaaa0690737a7f5a533123694cb54a3ab6bb59",
  RestingOrderCancelled: "0x5c7a275ab57943730699c7532f195cdc6df979a7c2daa5505b98776743b78b43",
  ConditionalExpirySet: "0x6ac94779a4132cd34f3554e13f73dac66ac7b8473a07533cfb75e95a25796568",
  ConditionalOrderExpired: "0xba6fb42987fa848214e1adfd457e469aab8135e61a05eb5e27be8a9cf171682e",
  TrailingOrderPlaced: "0x2c87f9624dc6b32ae366e1c0a397696bd13eb3e088e38b791f71996b7d350f4c",
  TrailingOrderCancelled: "0x472788c6b4f185ea1eecebb5b3b124d0161f9789d6e6e015d71b78f5786e81f2",
  TrailingExpirySet: "0x44e61e466659d3ddc448dae3c1265ad1c1dea3526fce8b82308d00aa64b8ed70",
  TrailingOrderExpired: "0x098aeadd44bb2338f1a0590d28ef3df3b68c27dde5b8e8524c43e5e1ace84a48",
  TrailingOrderExecuted: "0x0bd8a60a5c8994e48737f10308a9b320a3d5de9df0717fbfc59bb1be6d826cc4",
  ManagedQuoteUpdated: "0xad27c166ac1272b346030388fc9e334bf7a0dea2a784740aa2e42bf48c1ed1e7",
  ManagedQuoteRemoved: "0x79422a4e5b30e6b1b54a72aec21e1b5ea1f753f154b5a98aed93b2386e606616",
  PortfolioLockSynchronized: "0xcec4da35887e0ef4131ced31e477e7f049b273c199470103deca293d6651f2de",
} as const;

export const CANONICAL_EVENT_TOPICS = Object.freeze({ ...TOPICS });

function requireShape(log: RawRpcLog, topicCount: number, dataWords: number): void {
  if (log.topics.length !== topicCount) {
    throw new IndexerError(
      `malformed protocol log: expected ${topicCount} topics, got ${log.topics.length}`,
    );
  }
  if (!/^0x[0-9a-fA-F]*$/.test(log.data) || log.data.length !== 2 + dataWords * 64) {
    throw new IndexerError(
      `malformed protocol log: expected ${dataWords} ABI data words`,
    );
  }
  for (const topic of log.topics) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(topic)) {
      throw new IndexerError("malformed protocol log topic");
    }
  }
}

function topicUint(log: RawRpcLog, index: number): bigint {
  return BigInt(log.topics[index]);
}

function dataUint(log: RawRpcLog, index: number): bigint {
  const start = 2 + index * 64;
  return BigInt(`0x${log.data.slice(start, start + 64)}`);
}

function dataInt(log: RawRpcLog, index: number): bigint {
  const raw = dataUint(log, index);
  return raw >= (1n << 255n) ? raw - (1n << 256n) : raw;
}

function uintValue(value: bigint, field: string, max: bigint): bigint {
  if (value < 0n || value > max) throw new IndexerError(`${field} is out of range`);
  return value;
}

function uintNumber(value: bigint, field: string, max: bigint): number {
  return Number(uintValue(value, field, max));
}

function boolValue(value: bigint, field: string): boolean {
  if (value === 0n) return false;
  if (value === 1n) return true;
  throw new IndexerError(`${field} is not a canonical ABI bool`);
}

function orderId(log: RawRpcLog, topicIndex = 1): bigint {
  return uintValue(topicUint(log, topicIndex), "orderId", (1n << 64n) - 1n);
}

function side(value: bigint): 0 | 1 {
  const decoded = uintNumber(value, "side", 1n);
  return decoded as 0 | 1;
}

function topicAddress(log: RawRpcLog, index: number): Address {
  const topic = log.topics[index];
  if (BigInt(`0x${topic.slice(2, 26)}`) !== 0n) {
    throw new IndexerError("indexed address has non-zero ABI padding");
  }
  return `0x${topic.slice(-40)}` as Address;
}

function decodeLiquidityAdded(log: RawRpcLog): DecodedProtocolEvent {
  requireShape(log, 4, 3);
  topicAddress(log, 1);
  const lots = uintValue(dataUint(log, 0), "lots", (1n << 96n) - 1n);
  uintValue(dataUint(log, 1), "shares", (1n << 128n) - 1n);
  return {
    name: "LiquidityAdded",
    side: side(topicUint(log, 2)),
    tick: uintNumber(topicUint(log, 3), "tick", 0xffffn),
    lots,
    generation: uintNumber(dataUint(log, 2), "generation", 0xffffffffn),
  };
}

function decodeLiquidityRemoved(log: RawRpcLog): DecodedProtocolEvent {
  requireShape(log, 4, 3);
  topicAddress(log, 1);
  const lots = uintValue(dataUint(log, 0), "lots", (1n << 96n) - 1n);
  uintValue(dataUint(log, 1), "shares", (1n << 128n) - 1n);
  return {
    name: "LiquidityRemoved",
    side: side(topicUint(log, 2)),
    tick: uintNumber(topicUint(log, 3), "tick", 0xffffn),
    lots,
    generation: uintNumber(dataUint(log, 2), "generation", 0xffffffffn),
  };
}

function decodeTrade(log: RawRpcLog): DecodedProtocolEvent {
  requireShape(log, 4, 1);
  topicAddress(log, 1);
  return {
    name: "Trade",
    takerSide: side(topicUint(log, 2)),
    tick: uintNumber(topicUint(log, 3), "tick", 0xffffn),
    lots: uintValue(dataUint(log, 0), "lots", (1n << 96n) - 1n),
  };
}

function indexedOrder(log: RawRpcLog): bigint {
  requireShape(log, 2, 0);
  return orderId(log);
}

const DECODERS = new Map<string, Decoder>([
  [TOPICS.LiquidityAdded, decodeLiquidityAdded],
  [TOPICS.LiquidityRemoved, decodeLiquidityRemoved],
  [TOPICS.Trade, decodeTrade],
  [TOPICS.ConditionalOrderPlaced, (log) => {
    requireShape(log, 3, 7);
    return { name: "ConditionalOrderPlaced", orderId: topicUint(log, 1) };
  }],
  [TOPICS.ConditionalOrderCancelled, (log) => ({
    name: "ConditionalOrderCancelled",
    orderId: indexedOrder(log),
  })],
  [TOPICS.ConditionalOrderExecuted, (log) => {
    requireShape(log, 2, 1);
    return { name: "ConditionalOrderExecuted", orderId: topicUint(log, 1) };
  }],
  [TOPICS.OCOLinked, (log) => {
    requireShape(log, 3, 0);
    return {
      name: "OCOLinked",
      firstOrderId: topicUint(log, 1),
      secondOrderId: topicUint(log, 2),
    };
  }],
  [TOPICS.OTOLinked, (log) => {
    requireShape(log, 3, 0);
    return {
      name: "OTOLinked",
      parentOrderId: topicUint(log, 1),
      childOrderId: topicUint(log, 2),
    };
  }],
  [TOPICS.OTOActivated, (log) => {
    requireShape(log, 3, 1);
    return {
      name: "OTOActivated",
      parentOrderId: topicUint(log, 1),
      childOrderId: topicUint(log, 2),
      lots: dataUint(log, 0),
    };
  }],
  [TOPICS.OTOResized, (log) => {
    requireShape(log, 3, 1);
    return {
      name: "OTOResized",
      parentOrderId: topicUint(log, 1),
      childOrderId: topicUint(log, 2),
      lots: dataUint(log, 0),
    };
  }],
  [TOPICS.RestingOrderLinked, (log) => {
    requireShape(log, 2, 3);
    return { name: "RestingOrderLinked", orderId: topicUint(log, 1) };
  }],
  [TOPICS.RestingOrderSynced, (log) => {
    requireShape(log, 2, 3);
    return {
      name: "RestingOrderSynced",
      orderId: topicUint(log, 1),
      remainingLots: dataUint(log, 2),
    };
  }],
  [TOPICS.RestingOrderCancelled, (log) => {
    requireShape(log, 2, 1);
    return { name: "RestingOrderCancelled", orderId: topicUint(log, 1) };
  }],
  [TOPICS.ConditionalExpirySet, (log) => {
    requireShape(log, 2, 1);
    return {
      name: "ConditionalExpirySet",
      orderId: topicUint(log, 1),
      expiry: dataUint(log, 0),
    };
  }],
  [TOPICS.ConditionalOrderExpired, (log) => ({
    name: "ConditionalOrderExpired",
    orderId: indexedOrder(log),
  })],
  [TOPICS.TrailingOrderPlaced, (log) => {
    requireShape(log, 3, 6);
    return { name: "TrailingOrderPlaced", orderId: topicUint(log, 1) };
  }],
  [TOPICS.TrailingOrderCancelled, (log) => ({
    name: "TrailingOrderCancelled",
    orderId: indexedOrder(log),
  })],
  [TOPICS.TrailingExpirySet, (log) => {
    requireShape(log, 2, 1);
    return {
      name: "TrailingExpirySet",
      orderId: topicUint(log, 1),
      expiry: dataUint(log, 0),
    };
  }],
  [TOPICS.TrailingOrderExpired, (log) => ({
    name: "TrailingOrderExpired",
    orderId: indexedOrder(log),
  })],
  [TOPICS.TrailingOrderExecuted, (log) => {
    requireShape(log, 2, 3);
    return { name: "TrailingOrderExecuted", orderId: topicUint(log, 1) };
  }],
  [TOPICS.ManagedQuoteUpdated, (log) => {
    requireShape(log, 4, 2);
    return {
      name: "ManagedQuoteUpdated",
      maker: topicAddress(log, 1),
      side: side(topicUint(log, 2)),
      tick: uintNumber(topicUint(log, 3), "tick", 0xffffn),
      shares: dataUint(log, 0),
      generation: uintNumber(dataUint(log, 1), "generation", 0xffffffffn),
    };
  }],
  [TOPICS.ManagedQuoteRemoved, (log) => {
    requireShape(log, 4, 2);
    return {
      name: "ManagedQuoteRemoved",
      maker: topicAddress(log, 1),
      side: side(topicUint(log, 2)),
      tick: uintNumber(topicUint(log, 3), "tick", 0xffffn),
    };
  }],
  [TOPICS.PortfolioLockSynchronized, (log) => {
    requireShape(log, 2, 3);
    return {
      name: "PortfolioLockSynchronized",
      account: topicAddress(log, 1),
      equity: dataInt(log, 0),
      requirement: dataUint(log, 1),
      lockedCollateral: dataUint(log, 2),
    };
  }],
]);

export function decodeProtocolLog(
  log: RawRpcLog,
  _manifest?: DeploymentManifest,
): DecodedProtocolEvent | undefined {
  if (log.topics.length === 0) return undefined;
  const decoder = DECODERS.get(log.topics[0].toLowerCase());
  return decoder?.(log);
}

export const canonicalProtocolLogDecoder = decodeProtocolLog;

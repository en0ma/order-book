import test from "node:test";
import assert from "node:assert/strict";

import {
  CANONICAL_EVENT_TOPICS,
  decodeProtocolLog,
} from "../dist/abi.js";
import { ReferenceNodeService } from "../dist/node.js";

const ADDRESS = "0x1111111111111111111111111111111111111111";
const MAKER = "0x2222222222222222222222222222222222222222";
const ACCOUNT = "0x3333333333333333333333333333333333333333";

function word(value: bigint | number): string {
  return BigInt(value).toString(16).padStart(64, "0");
}

function signedWord(value: bigint): string {
  const normalized = value < 0n ? (1n << 256n) + value : value;
  return word(normalized);
}

function addressTopic(address: string): `0x${string}` {
  return `0x${address.slice(2).padStart(64, "0")}`;
}

function raw(
  topic0: `0x${string}`,
  topics: readonly `0x${string}`[],
  words: readonly string[],
) {
  return {
    address: ADDRESS as `0x${string}`,
    blockNumber: "0x64" as const,
    blockHash: "0xabc",
    transactionIndex: "0x0" as const,
    logIndex: "0x0" as const,
    topics: [topic0, ...topics],
    data: `0x${words.join("")}` as `0x${string}`,
  };
}

test("decodes canonical core liquidity and trade events", () => {
  assert.deepEqual(
    decodeProtocolLog(
      raw(
        CANONICAL_EVENT_TOPICS.LiquidityAdded,
        [
          addressTopic(MAKER),
          `0x${word(1)}`,
          `0x${word(105)}`,
        ],
        [word(40), word(40), word(7)],
      ),
    ),
    {
      name: "LiquidityAdded",
      side: 1,
      tick: 105,
      lots: 40n,
      generation: 7,
    },
  );

  assert.deepEqual(
    decodeProtocolLog(
      raw(
        CANONICAL_EVENT_TOPICS.Trade,
        [
          addressTopic(ACCOUNT),
          `0x${word(0)}`,
          `0x${word(105)}`,
        ],
        [word(11)],
      ),
    ),
    {
      name: "Trade",
      takerSide: 0,
      tick: 105,
      lots: 11n,
    },
  );
});

test("decodes advanced composition lifecycle events", () => {
  assert.deepEqual(
    decodeProtocolLog(
      raw(
        CANONICAL_EVENT_TOPICS.OTOActivated,
        [`0x${word(12)}`, `0x${word(13)}`],
        [word(9)],
      ),
    ),
    {
      name: "OTOActivated",
      parentOrderId: 12n,
      childOrderId: 13n,
      lots: 9n,
    },
  );

  assert.deepEqual(
    decodeProtocolLog(
      raw(
        CANONICAL_EVENT_TOPICS.RestingOrderSynced,
        [`0x${word(12)}`],
        [word(2), word(8), word(5)],
      ),
    ),
    {
      name: "RestingOrderSynced",
      orderId: 12n,
      remainingLots: 5n,
    },
  );
});

test("decodes market maker and signed portfolio events", () => {
  assert.deepEqual(
    decodeProtocolLog(
      raw(
        CANONICAL_EVENT_TOPICS.ManagedQuoteUpdated,
        [
          addressTopic(MAKER),
          `0x${word(1)}`,
          `0x${word(110)}`,
        ],
        [word(15), word(3)],
      ),
    ),
    {
      name: "ManagedQuoteUpdated",
      maker: MAKER,
      side: 1,
      tick: 110,
      shares: 15n,
      generation: 3,
    },
  );

  assert.deepEqual(
    decodeProtocolLog(
      raw(
        CANONICAL_EVENT_TOPICS.PortfolioLockSynchronized,
        [addressTopic(ACCOUNT)],
        [signedWord(-25n), word(300), word(275)],
      ),
    ),
    {
      name: "PortfolioLockSynchronized",
      account: ACCOUNT,
      equity: -25n,
      requirement: 300n,
      lockedCollateral: 275n,
    },
  );
});

test("ignores unknown events but fails closed on malformed known events", () => {
  assert.equal(
    decodeProtocolLog(
      raw(
        "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        [],
        [],
      ),
    ),
    undefined,
  );

  assert.throws(
    () =>
      decodeProtocolLog(
        raw(
          CANONICAL_EVENT_TOPICS.Trade,
          [addressTopic(ACCOUNT)],
          [word(1)],
        ),
      ),
    /expected 4 topics/,
  );

  assert.throws(
    () =>
      decodeProtocolLog(
        raw(
          CANONICAL_EVENT_TOPICS.ManagedQuoteUpdated,
          [
            `0x${"ff".repeat(12)}${MAKER.slice(2)}`,
            `0x${word(0)}`,
            `0x${word(100)}`,
          ],
          [word(1), word(0)],
        ),
      ),
    /non-zero ABI padding/,
  );
});

test("Node service exposes the canonical decoder path without custom glue", async () => {
  const manifest = {
    schemaVersion: 1,
    chainId: 1,
    deploymentBlock: 100,
    packageVersion: "0.1.0",
    collateral: {
      token: "0x4444444444444444444444444444444444444444",
      decimals: 18,
    },
    markets: [
      {
        id: "ETH-PERP",
        core: "0x5555555555555555555555555555555555555555",
        advanced: "0x6666666666666666666666666666666666666666",
        oracle: "0x7777777777777777777777777777777777777777",
        scales: { collateralUnitsPerLotTick: "1" },
        parameters: {
          executionBandTicks: 40,
          initialMarginBps: 1000,
          takerFeeBps: 5,
          makerRebateBps: 2,
        },
      },
    ],
  };

  const rpc = {
    async chainId() {
      return 1;
    },
  };
  const store = {
    async load() {
      return undefined;
    },
  };

  const service = await ReferenceNodeService.createCanonical(
    manifest,
    rpc,
    store,
  );
  assert.equal(typeof service.decoder, "function");
  assert.equal(service.decoder, decodeProtocolLog);
});

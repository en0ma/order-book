import test from "node:test";
import assert from "node:assert/strict";

import {
  IndexerError,
  ReferenceIndexer,
  type Address,
  type DeploymentManifest,
  type IndexedBlock,
  type ProtocolLog,
} from "../dist/index.js";

const CORE = "0x1111111111111111111111111111111111111111" as Address;
const ADVANCED = "0x2222222222222222222222222222222222222222" as Address;
const MM = "0x3333333333333333333333333333333333333333" as Address;
const ORACLE = "0x4444444444444444444444444444444444444444" as Address;
const COORDINATOR = "0x5555555555555555555555555555555555555555" as Address;
const POLICY = "0x6666666666666666666666666666666666666666" as Address;
const VAULT = "0x7777777777777777777777777777777777777777" as Address;
const TOKEN = "0x8888888888888888888888888888888888888888" as Address;
const MAKER = "0x9999999999999999999999999999999999999999" as Address;
const ACCOUNT = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as Address;

function manifest(): DeploymentManifest {
  return {
    schemaVersion: 1,
    chainId: 1,
    deploymentBlock: 100,
    packageVersion: "0.1.0",
    collateral: { token: TOKEN, decimals: 6 },
    portfolio: {
      coordinator: COORDINATOR,
      policy: POLICY,
      vault: VAULT,
    },
    markets: [
      {
        id: "ETH-PERP",
        core: CORE,
        advanced: ADVANCED,
        marketMaker: MM,
        oracle: ORACLE,
        portfolioMarketIndex: 0,
        scales: { collateralUnitsPerLotTick: "1000" },
        parameters: {
          executionBandTicks: 40,
          initialMarginBps: 1000,
          takerFeeBps: 5,
          makerRebateBps: 2,
        },
      },
    ],
  };
}

function log(
  blockNumber: number,
  blockHash: string,
  transactionIndex: number,
  logIndex: number,
  address: Address,
  event: ProtocolLog["event"],
): ProtocolLog {
  return {
    blockNumber,
    blockHash,
    transactionIndex,
    logIndex,
    address,
    event,
  };
}

function block(
  number: number,
  hash: string,
  parentHash: string,
  logs: readonly ProtocolLog[],
): IndexedBlock {
  return { chainId: 1, number, hash, parentHash, logs };
}

test("replays core pools in canonical log order and advances exhausted generation", () => {
  const indexer = new ReferenceIndexer(manifest());

  indexer.applyBlock(
    block(100, "0x100", "0x099", [
      log(100, "0x100", 1, 1, CORE, {
        name: "Trade",
        takerSide: 0,
        tick: 105,
        lots: 10n,
      }),
      log(100, "0x100", 0, 0, CORE, {
        name: "LiquidityAdded",
        side: 1,
        tick: 105,
        lots: 40n,
        generation: 0,
      }),
    ]),
  );

  assert.deepEqual(indexer.snapshotState().pools["ETH-PERP:1:105"], {
    remainingLots: "30",
    generation: 0,
  });

  indexer.applyBlock(
    block(101, "0x101", "0x100", [
      log(101, "0x101", 0, 0, CORE, {
        name: "Trade",
        takerSide: 0,
        tick: 105,
        lots: 30n,
      }),
    ]),
  );

  assert.deepEqual(indexer.snapshotState().pools["ETH-PERP:1:105"], {
    remainingLots: "0",
    generation: 1,
  });
});

test("deduplicates repeated log delivery and repeated block delivery", () => {
  const indexer = new ReferenceIndexer(manifest());
  const added = log(100, "0x100", 0, 0, CORE, {
    name: "LiquidityAdded",
    side: 0,
    tick: 95,
    lots: 12n,
    generation: 0,
  });
  const first = block(100, "0x100", "0x099", [added, added]);

  indexer.applyBlock(first);
  indexer.applyBlock(first);

  assert.equal(
    indexer.snapshotState().pools["ETH-PERP:0:95"].remainingLots,
    "12",
  );
});

test("ignores redelivery of a retained canonical non-head block", () => {
  const indexer = new ReferenceIndexer(manifest(), { maxReorgDepth: 8 });
  const block100 = block(100, "0x100", "0x099", [
    log(100, "0x100", 0, 0, CORE, {
      name: "LiquidityAdded",
      side: 0,
      tick: 95,
      lots: 20n,
      generation: 0,
    }),
  ]);
  indexer.applyBlock(block100);
  indexer.applyBlock(
    block(101, "0x101", "0x100", [
      log(101, "0x101", 0, 0, CORE, {
        name: "Trade",
        takerSide: 1,
        tick: 95,
        lots: 3n,
      }),
    ]),
  );

  indexer.applyBlock(block100);

  assert.deepEqual(indexer.head(), { number: 101, hash: "0x101" });
  assert.equal(
    indexer.snapshotState().pools["ETH-PERP:0:95"].remainingLots,
    "17",
  );
});


test("rolls back an orphaned block and applies the canonical sibling", () => {
  const indexer = new ReferenceIndexer(manifest(), { maxReorgDepth: 8 });

  indexer.applyBlock(
    block(100, "0x100", "0x099", [
      log(100, "0x100", 0, 0, CORE, {
        name: "LiquidityAdded",
        side: 1,
        tick: 105,
        lots: 40n,
        generation: 0,
      }),
    ]),
  );

  indexer.applyBlock(
    block(101, "0x101-orphan", "0x100", [
      log(101, "0x101-orphan", 0, 0, CORE, {
        name: "Trade",
        takerSide: 0,
        tick: 105,
        lots: 11n,
      }),
    ]),
  );

  indexer.applyBlock(
    block(101, "0x101-canonical", "0x100", [
      log(101, "0x101-canonical", 0, 0, CORE, {
        name: "Trade",
        takerSide: 0,
        tick: 105,
        lots: 7n,
      }),
      log(101, "0x101-canonical", 1, 0, CORE, {
        name: "LiquidityAdded",
        side: 1,
        tick: 105,
        lots: 5n,
        generation: 0,
      }),
    ]),
  );

  assert.deepEqual(indexer.head(), { number: 101, hash: "0x101-canonical" });
  assert.equal(
    indexer.snapshotState().pools["ETH-PERP:1:105"].remainingLots,
    "38",
  );
});

test("restores a checkpoint and continues from the exact next block", () => {
  const first = new ReferenceIndexer(manifest());
  first.applyBlock(
    block(100, "0x100", "0x099", [
      log(100, "0x100", 0, 0, CORE, {
        name: "LiquidityAdded",
        side: 0,
        tick: 95,
        lots: 20n,
        generation: 0,
      }),
    ]),
  );

  const recovered = new ReferenceIndexer(manifest(), {
    checkpoint: first.checkpoint(),
  });
  recovered.applyBlock(
    block(101, "0x101", "0x100", [
      log(101, "0x101", 0, 0, CORE, {
        name: "Trade",
        takerSide: 1,
        tick: 95,
        lots: 6n,
      }),
    ]),
  );

  assert.equal(
    recovered.snapshotState().pools["ETH-PERP:0:95"].remainingLots,
    "14",
  );
});

test("reconstructs conditional resting and GTD lifecycle", () => {
  const indexer = new ReferenceIndexer(manifest());

  indexer.applyBlock(
    block(100, "0x100", "0x099", [
      log(100, "0x100", 0, 0, ADVANCED, {
        name: "ConditionalOrderPlaced",
        orderId: 1n,
      }),
      log(100, "0x100", 0, 1, ADVANCED, {
        name: "ConditionalExpirySet",
        orderId: 1n,
        expiry: 1_000n,
      }),
      log(100, "0x100", 1, 0, ADVANCED, {
        name: "RestingOrderLinked",
        orderId: 1n,
      }),
      log(100, "0x100", 1, 1, ADVANCED, {
        name: "ConditionalOrderExecuted",
        orderId: 1n,
      }),
    ]),
  );

  assert.deepEqual(indexer.snapshotState().conditionals["ETH-PERP:1"], {
    active: false,
    dormant: false,
    expiry: "1000",
    resting: true,
  });

  indexer.applyBlock(
    block(101, "0x101", "0x100", [
      log(101, "0x101", 0, 0, ADVANCED, {
        name: "RestingOrderSynced",
        orderId: 1n,
        remainingLots: 0n,
      }),
    ]),
  );

  assert.deepEqual(indexer.snapshotState().conditionals["ETH-PERP:1"], {
    active: false,
    dormant: false,
    expiry: "0",
    resting: false,
  });
});

test("tracks OTO child dormancy and activation", () => {
  const indexer = new ReferenceIndexer(manifest());

  indexer.applyBlock(
    block(100, "0x100", "0x099", [
      log(100, "0x100", 0, 0, ADVANCED, {
        name: "ConditionalOrderPlaced",
        orderId: 1n,
      }),
      log(100, "0x100", 0, 1, ADVANCED, {
        name: "ConditionalOrderPlaced",
        orderId: 2n,
      }),
      log(100, "0x100", 1, 0, ADVANCED, {
        name: "OTOLinked",
        parentOrderId: 1n,
        childOrderId: 2n,
      }),
    ]),
  );

  let child = indexer.snapshotState().conditionals["ETH-PERP:2"];
  assert.equal(child.active, false);
  assert.equal(child.dormant, true);

  indexer.applyBlock(
    block(101, "0x101", "0x100", [
      log(101, "0x101", 0, 0, ADVANCED, {
        name: "OTOActivated",
        parentOrderId: 1n,
        childOrderId: 2n,
        lots: 5n,
      }),
    ]),
  );

  child = indexer.snapshotState().conditionals["ETH-PERP:2"];
  assert.equal(child.active, true);
  assert.equal(child.dormant, false);
  assert.equal(child.parent, "1");
});

test("reconstructs OCO and OTO graph relationships", () => {
  const indexer = new ReferenceIndexer(manifest());

  indexer.applyBlock(
    block(100, "0x100", "0x099", [
      log(100, "0x100", 0, 0, ADVANCED, {
        name: "ConditionalOrderPlaced",
        orderId: 1n,
      }),
      log(100, "0x100", 0, 1, ADVANCED, {
        name: "ConditionalOrderPlaced",
        orderId: 2n,
      }),
      log(100, "0x100", 0, 2, ADVANCED, {
        name: "ConditionalOrderPlaced",
        orderId: 3n,
      }),
      log(100, "0x100", 1, 0, ADVANCED, {
        name: "OCOLinked",
        firstOrderId: 2n,
        secondOrderId: 3n,
      }),
      log(100, "0x100", 1, 1, ADVANCED, {
        name: "OTOLinked",
        parentOrderId: 1n,
        childOrderId: 2n,
      }),
      log(100, "0x100", 1, 2, ADVANCED, {
        name: "OTOLinked",
        parentOrderId: 1n,
        childOrderId: 3n,
      }),
    ]),
  );

  const state = indexer.snapshotState().conditionals;
  assert.deepEqual(state["ETH-PERP:1"].children, ["2", "3"]);
  assert.equal(state["ETH-PERP:2"].parent, "1");
  assert.equal(state["ETH-PERP:2"].sibling, "3");
  assert.equal(state["ETH-PERP:3"].sibling, "2");
});

test("reconstructs managed MM quote and portfolio lock state", () => {
  const indexer = new ReferenceIndexer(manifest());

  indexer.applyBlock(
    block(100, "0x100", "0x099", [
      log(100, "0x100", 0, 0, MM, {
        name: "ManagedQuoteUpdated",
        maker: MAKER,
        side: 1,
        tick: 110,
        shares: 15n,
        generation: 3,
      }),
      log(100, "0x100", 1, 0, COORDINATOR, {
        name: "PortfolioLockSynchronized",
        account: ACCOUNT,
        equity: 20_000n,
        requirement: 3_000n,
        lockedCollateral: 3_000n,
      }),
    ]),
  );

  const state = indexer.snapshotState();
  assert.deepEqual(
    state.managedQuotes[
      "ETH-PERP:0x9999999999999999999999999999999999999999:1:110"
    ],
    { shares: "15", generation: 3 },
  );
  assert.deepEqual(
    state.portfolioLocks["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
    { equity: "20000", requirement: "3000", lockedCollateral: "3000" },
  );

  indexer.applyBlock(
    block(101, "0x101", "0x100", [
      log(101, "0x101", 0, 0, MM, {
        name: "ManagedQuoteRemoved",
        maker: MAKER,
        side: 1,
        tick: 110,
      }),
    ]),
  );

  assert.equal(
    indexer.snapshotState().managedQuotes[
      "ETH-PERP:0x9999999999999999999999999999999999999999:1:110"
    ],
    undefined,
  );
});

test("rejects protocol events from contracts outside the manifest", () => {
  const indexer = new ReferenceIndexer(manifest());
  const wrong = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as Address;

  assert.throws(
    () =>
      indexer.applyBlock(
        block(100, "0x100", "0x099", [
          log(100, "0x100", 0, 0, wrong, {
            name: "LiquidityAdded",
            side: 0,
            tick: 95,
            lots: 1n,
            generation: 0,
          }),
        ]),
      ),
    /unexpected contract/,
  );

  assert.equal(indexer.head(), undefined);
});

test("requires fresh replay to start exactly at deploymentBlock", () => {
  const indexer = new ReferenceIndexer(manifest());

  assert.throws(
    () => indexer.applyBlock(block(101, "0x101", "0x100", [])),
    /deploymentBlock/,
  );
});

test("failed sibling application leaves the prior head and history intact", () => {
  const indexer = new ReferenceIndexer(manifest(), { maxReorgDepth: 8 });

  indexer.applyBlock(
    block(100, "0x100", "0x099", [
      log(100, "0x100", 0, 0, CORE, {
        name: "LiquidityAdded",
        side: 0,
        tick: 95,
        lots: 20n,
        generation: 0,
      }),
    ]),
  );
  indexer.applyBlock(block(101, "0x101", "0x100", []));

  assert.throws(
    () =>
      indexer.applyBlock(
        block(101, "0x101-bad", "0x100", [
          log(101, "0x101-bad", 0, 0, CORE, {
            name: "Trade",
            takerSide: 1,
            tick: 95,
            lots: 99n,
          }),
        ]),
      ),
    /exceeds replayed pool lots/,
  );

  assert.deepEqual(indexer.head(), { number: 101, hash: "0x101" });

  indexer.applyBlock(block(102, "0x102", "0x101", []));
  assert.deepEqual(indexer.head(), { number: 102, hash: "0x102" });
});

test("checkpoint size does not retain historical log identities", () => {
  const indexer = new ReferenceIndexer(manifest(), { maxReorgDepth: 2 });
  for (let number = 100; number <= 104; number += 1) {
    const hash = `0x${number}`;
    const parent = number === 100 ? "0x099" : `0x${number - 1}`;
    indexer.applyBlock(
      block(number, hash, parent, [
        log(number, hash, 0, 0, CORE, {
          name: "LiquidityAdded",
          side: 0,
          tick: 95,
          lots: 1n,
          generation: 0,
        }),
      ]),
    );
  }

  const checkpoint = indexer.checkpoint() as unknown as Record<string, unknown>;
  assert.equal("seenLogIds" in checkpoint, false);
  assert.equal(JSON.stringify(checkpoint).includes("0x100:0:0"), false);
});

test("rejects a reorg beyond retained history", () => {
  const indexer = new ReferenceIndexer(manifest(), { maxReorgDepth: 1 });
  indexer.applyBlock(block(100, "0x100", "0x099", []));
  indexer.applyBlock(block(101, "0x101", "0x100", []));
  indexer.applyBlock(block(102, "0x102", "0x101", []));

  assert.throws(
    () => indexer.applyBlock(block(101, "0x101b", "0x100", [])),
    IndexerError,
  );
});

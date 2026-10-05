import test from "node:test";
import assert from "node:assert/strict";

import {
  ReferenceIndexer,
  executeKeeperTasks,
  planKeeperTasks,
  syncOperatorOnce,
  validateOperatorManifest,
  type NormalizedEvent,
  type OperatorManifest,
} from "../dist/index.js";

const CORE = "0x1111111111111111111111111111111111111111";
const ADV = "0x2222222222222222222222222222222222222222";
const ALICE = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

function event(
  blockNumber: number,
  blockHash: string,
  transactionIndex: number,
  logIndex: number,
  name: string,
  args: Record<string, unknown>,
  marketId = "ETH-PERP",
): NormalizedEvent {
  return {
    chainId: 1,
    blockNumber,
    transactionIndex,
    logIndex,
    blockHash,
    address: name.startsWith("Portfolio") ? ADV : CORE,
    marketId,
    name,
    args,
  };
}

test("reconstructs pools in canonical log order", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 10, hash: "0x10", parentHash: "0x09" },
    [
      event(10, "0x10", 1, 1, "Trade", { side: 0, tick: 105, lots: 4n }),
      event(10, "0x10", 0, 1, "LiquidityAdded", {
        account: ALICE,
        side: 1,
        tick: 105,
        lots: 10n,
        generation: 0,
      }),
    ],
  );

  assert.deepEqual(indexer.state.pools.get("ETH-PERP:1:105"), {
    remainingLots: 6n,
    generation: 0,
  });
});

test("advances pool generation when a trade drains the level", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [
      event(1, "0xa", 0, 0, "LiquidityAdded", {
        account: ALICE,
        side: 1,
        tick: 105,
        lots: 5n,
        generation: 7,
      }),
      event(1, "0xa", 0, 1, "Trade", { side: 0, tick: 105, lots: 5n }),
    ],
  );

  assert.deepEqual(indexer.state.pools.get("ETH-PERP:1:105"), {
    remainingLots: 0n,
    generation: 8,
  });
});

test("rolls back an orphaned branch and applies its canonical replacement", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [event(1, "0xa", 0, 0, "LiquidityAdded", {
      account: ALICE,
      side: 1,
      tick: 105,
      lots: 20n,
      generation: 0,
    })],
  );
  indexer.applyBlock(
    { number: 2, hash: "0xb-old", parentHash: "0xa" },
    [event(2, "0xb-old", 0, 0, "Trade", { side: 0, tick: 105, lots: 11n })],
  );

  assert.equal(indexer.state.pools.get("ETH-PERP:1:105")?.remainingLots, 9n);

  indexer.rollbackTo(1);
  indexer.applyBlock(
    { number: 2, hash: "0xb-new", parentHash: "0xa" },
    [event(2, "0xb-new", 0, 0, "Trade", { side: 0, tick: 105, lots: 7n })],
  );

  assert.equal(indexer.state.pools.get("ETH-PERP:1:105")?.remainingLots, 13n);
  assert.equal(indexer.headBlock()?.hash, "0xb-new");
});

test("rejects a non-canonical parent until caller rolls back", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock({ number: 1, hash: "0xa", parentHash: "0x0" }, []);

  assert.throws(
    () => indexer.applyBlock({ number: 2, hash: "0xb", parentHash: "0xwrong" }, []),
    /rollback to the common ancestor/,
  );
});

test("keeper only schedules conditionals whose trigger is satisfied", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [event(1, "0xa", 0, 0, "ConditionalOrderPlaced", {
      orderId: 7n,
      owner: ALICE,
      triggerAboveOrEqual: true,
      triggerTick: 110,
    })],
  );

  assert.deepEqual(
    planKeeperTasks(indexer.state, { now: 1n, markTicks: { "ETH-PERP": 109 } }),
    [],
  );
  assert.deepEqual(
    planKeeperTasks(indexer.state, { now: 1n, markTicks: { "ETH-PERP": 110 } }),
    [{ kind: "executeConditional", marketId: "ETH-PERP", orderId: 7n }],
  );
});

test("expiry takes priority over trigger execution", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [
      event(1, "0xa", 0, 0, "ConditionalOrderPlaced", {
        orderId: 7n,
        owner: ALICE,
        triggerAboveOrEqual: true,
        triggerTick: 100,
      }),
      event(1, "0xa", 0, 1, "ConditionalExpirySet", {
        orderId: 7n,
        expiry: 50n,
      }),
    ],
  );

  assert.deepEqual(
    planKeeperTasks(indexer.state, { now: 50n, markTicks: { "ETH-PERP": 120 } }),
    [{ kind: "expireConditional", marketId: "ETH-PERP", orderId: 7n }],
  );
});

test("resting parents are queued for sync and retain expiry", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [
      event(1, "0xa", 0, 0, "ConditionalOrderPlaced", {
        orderId: 9n,
        owner: ALICE,
        triggerAboveOrEqual: true,
        triggerTick: 100,
      }),
      event(1, "0xa", 0, 1, "ConditionalExpirySet", { orderId: 9n, expiry: 500n }),
      event(1, "0xa", 0, 2, "RestingOrderLinked", { parentOrderId: 9n }),
      event(1, "0xa", 0, 3, "ConditionalOrderExecuted", { orderId: 9n }),
    ],
  );

  assert.deepEqual(
    planKeeperTasks(indexer.state, { now: 100n, markTicks: {} }),
    [{ kind: "syncResting", marketId: "ETH-PERP", orderId: 9n }],
  );
  assert.equal(indexer.state.conditionals.get("ETH-PERP:9")?.expiry, 500n);
});

test("tracks MM recovery events and portfolio liquidation candidates", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [
      event(1, "0xa", 0, 0, "LiquidityAdded", {
        account: ALICE,
        side: 1,
        tick: 105,
        lots: 10n,
        generation: 0,
      }),
      event(1, "0xa", 0, 1, "ConditionalOrderPlaced", {
        orderId: 3n,
        owner: ALICE,
        triggerAboveOrEqual: false,
        triggerTick: 90,
      }),
      event(1, "0xa", 0, 2, "TrailingOrderPlaced", {
        orderId: 4n,
        owner: ALICE,
      }),
      event(1, "0xa", 0, 3, "ManagedQuoteUpdated", {
        maker: ALICE,
        side: 1,
        tick: 105,
        shares: 12n,
        generation: 0,
      }),
      event(1, "0xa", 0, 4, "PortfolioLockSynchronized", {
        account: ALICE,
        equity: 90n,
        requirement: 100n,
        lockedCollateral: 90n,
      }),
    ],
  );

  const tasks = planKeeperTasks(indexer.state, {
    now: 1n,
    markTicks: {},
    portfolioHealth: { [ALICE]: { equity: 90n, requirement: 100n } },
  });
  const liquidation = tasks.find((task) => task.kind === "liquidationCandidate");
  assert.deepEqual(liquidation, {
    kind: "liquidationCandidate",
    account: ALICE,
    knownMakerKeys: ["ETH-PERP:1:105"],
    conditionalIds: [3n],
    trailingIds: [4n],
  });

  assert.deepEqual(
    indexer.state.managedQuotes.get(`ETH-PERP:${ALICE}:1:105`),
    { shares: 12n, generation: 0 },
  );
});

test("terminal lifecycle removes advanced IDs from liquidation registry", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [
      event(1, "0xa", 0, 0, "ConditionalOrderPlaced", {
        orderId: 3n,
        owner: ALICE,
        triggerAboveOrEqual: true,
        triggerTick: 100,
      }),
      event(1, "0xa", 0, 1, "ConditionalOrderCancelled", { orderId: 3n }),
    ],
  );

  assert.equal(indexer.state.activeConditionalIds.get(ALICE), undefined);
});


test("block application is atomic when a later event is invalid", () => {
  const indexer = new ReferenceIndexer(1);
  assert.throws(
    () => indexer.applyBlock(
      { number: 1, hash: "0xa", parentHash: "0x0" },
      [
        event(1, "0xa", 0, 0, "LiquidityAdded", {
          account: ALICE,
          side: 1,
          tick: 105,
          lots: 10n,
          generation: 0,
        }),
        event(2, "0xb", 0, 1, "LiquidityAdded", {
          account: ALICE,
          side: 1,
          tick: 105,
          lots: 5n,
          generation: 0,
        }),
      ],
    ),
    /event does not belong/,
  );
  assert.equal(indexer.state.pools.size, 0);
  assert.equal(indexer.headBlock(), undefined);

  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [event(1, "0xa", 0, 0, "LiquidityAdded", {
      account: ALICE,
      side: 1,
      tick: 105,
      lots: 10n,
      generation: 0,
    })],
  );
  assert.equal(indexer.state.pools.get("ETH-PERP:1:105")?.remainingLots, 10n);
});

test("retains only the configured reorg window", () => {
  const indexer = new ReferenceIndexer(1, 2);
  indexer.applyBlock({ number: 1, hash: "0x1", parentHash: "0x0" }, []);
  indexer.applyBlock({ number: 2, hash: "0x2", parentHash: "0x1" }, []);
  indexer.applyBlock({ number: 3, hash: "0x3", parentHash: "0x2" }, []);

  assert.throws(() => indexer.rollbackTo(1), /rollback checkpoint unavailable/);
  indexer.rollbackTo(2);
  assert.equal(indexer.headBlock()?.hash, "0x2");
});

test("OTO child stays dormant until activation", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [
      event(1, "0xa", 0, 0, "ConditionalOrderPlaced", {
        orderId: 11n,
        owner: ALICE,
        triggerAboveOrEqual: true,
        triggerTick: 100,
      }),
      event(1, "0xa", 0, 1, "OTOLinked", {
        parentOrderId: 10n,
        childOrderId: 11n,
      }),
    ],
  );

  assert.deepEqual(
    planKeeperTasks(indexer.state, { now: 1n, markTicks: { "ETH-PERP": 120 } }),
    [],
  );
  assert.equal(indexer.state.conditionals.get("ETH-PERP:11")?.dormant, true);

  indexer.applyBlock(
    { number: 2, hash: "0xb", parentHash: "0xa" },
    [event(2, "0xb", 0, 0, "OTOActivated", {
      parentOrderId: 10n,
      childOrderId: 11n,
      lots: 5n,
    })],
  );

  assert.deepEqual(
    planKeeperTasks(indexer.state, { now: 1n, markTicks: { "ETH-PERP": 120 } }),
    [{ kind: "executeConditional", marketId: "ETH-PERP", orderId: 11n }],
  );
  assert.equal(indexer.state.conditionals.get("ETH-PERP:11")?.dormant, false);
});

test("liquidation planning uses current portfolio health input", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0xa", parentHash: "0x0" },
    [
      event(1, "0xa", 0, 0, "ConditionalOrderPlaced", {
        orderId: 3n,
        owner: ALICE,
        triggerAboveOrEqual: true,
        triggerTick: 100,
      }),
      event(1, "0xa", 0, 1, "PortfolioLockSynchronized", {
        account: ALICE,
        equity: 150n,
        requirement: 100n,
        lockedCollateral: 0n,
      }),
    ],
  );

  const tasks = planKeeperTasks(indexer.state, {
    now: 1n,
    markTicks: {},
    portfolioHealth: { [ALICE]: { equity: 80n, requirement: 100n } },
  });
  assert.deepEqual(tasks, [{
    kind: "liquidationCandidate",
    account: ALICE,
    knownMakerKeys: [],
    conditionalIds: [3n],
    trailingIds: [],
  }]);
});


const manifest: OperatorManifest = {
  schemaVersion: 1,
  chainId: 1,
  deploymentBlock: 1,
  collateral: {
    token: "0x9999999999999999999999999999999999999999",
    decimals: 6,
  },
  markets: [{
    id: "ETH-PERP",
    core: CORE,
    advanced: ADV,
    oracle: "0x3333333333333333333333333333333333333333",
  }],
};

test("validates self-hosted operator manifests", () => {
  assert.deepEqual(validateOperatorManifest(manifest), manifest);
  assert.throws(
    () => validateOperatorManifest({ ...manifest, chainId: 0 }),
    /chainId/,
  );
  assert.throws(
    () => validateOperatorManifest({
      ...manifest,
      collateral: {
        ...manifest.collateral,
        token: "0x0000000000000000000000000000000000000000",
      },
    }),
    /collateral\.token/,
  );
  assert.throws(
    () => validateOperatorManifest({
      ...manifest,
      portfolio: {
        coordinator: "0x4444444444444444444444444444444444444444",
        policy: "0x5555555555555555555555555555555555555555",
        vault: "0x6666666666666666666666666666666666666666",
      },
    }),
    /portfolioMarketIndex/,
  );
});

test("checkpoint round trip restores JSON-safe operator state", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0x1", parentHash: "0x0" },
    [event(1, "0x1", 0, 0, "LiquidityAdded", {
      account: ALICE,
      side: 1,
      tick: 101,
      lots: 9n,
      generation: 2,
    })],
  );

  const checkpoint = indexer.checkpoint(manifest);
  const encoded = JSON.stringify(checkpoint);
  assert.ok(encoded.includes('"ETH-PERP:1:101"'));
  assert.equal(checkpoint.deploymentBlock, manifest.deploymentBlock);

  const restored = new ReferenceIndexer(1);
  restored.restoreCheckpoint(checkpoint, manifest);
  assert.equal(restored.headBlock()?.hash, "0x1");
  assert.deepEqual(
    restored.state.pools.get("ETH-PERP:1:101"),
    { remainingLots: 9n, generation: 2 },
  );
assert.throws(
    () => restored.restoreCheckpoint(checkpoint, {
      ...manifest,
      deploymentBlock: manifest.deploymentBlock + 1,
    }),
    /checkpoint does not match deployment manifest/,
  );
});

test("runtime adapter catches up, rolls back a short reorg, and replans keepers", async () => {
  const blocks = new Map<number, { number: number; hash: string; parentHash: string }>([
    [1, { number: 1, hash: "0x1", parentHash: "0x0" }],
    [2, { number: 2, hash: "0x2a", parentHash: "0x1" }],
  ]);
  const logs = new Map<string, NormalizedEvent[]>([
    ["0x1", [event(1, "0x1", 0, 0, "ConditionalOrderPlaced", {
      orderId: 7n,
      owner: ALICE,
      triggerAboveOrEqual: true,
      triggerTick: 110,
    })]],
    ["0x2a", []],
    ["0x2b", [event(2, "0x2b", 0, 0, "ConditionalExpirySet", {
      orderId: 7n,
      expiry: 50n,
    })]],
  ]);

  const adapter = {
    async getChainId() { return 1; },
    async getHeadBlockNumber() { return 2; },
    async getBlock(number: number) {
      const block = blocks.get(number);
      if (!block) throw new Error("missing block");
      return block;
    },
    async getEvents(block: { hash: string }) { return logs.get(block.hash) ?? []; },
    async getMarkTicks() { return { "ETH-PERP": 120 }; },
    async getTimestamp() { return 10n; },
  };

  const indexer = new ReferenceIndexer(1, 8);
  const first = await syncOperatorOnce(manifest, indexer, adapter);
  assert.equal(first.appliedBlocks, 2);
  assert.deepEqual(first.tasks, [{
    kind: "executeConditional",
    marketId: "ETH-PERP",
    orderId: 7n,
  }]);

  blocks.set(2, { number: 2, hash: "0x2b", parentHash: "0x1" });
  const second = await syncOperatorOnce(manifest, indexer, adapter);
  assert.equal(second.rolledBackTo, 1);
  assert.equal(second.appliedBlocks, 1);
  assert.equal(indexer.headBlock()?.hash, "0x2b");
  assert.equal(indexer.state.conditionals.get("ETH-PERP:7")?.expiry, 50n);
});

test("portfolio runtime requires current health adapter support", async () => {
  const portfolioManifest: OperatorManifest = {
    ...manifest,
    portfolio: {
      coordinator: "0x4444444444444444444444444444444444444444",
      policy: "0x5555555555555555555555555555555555555555",
      vault: "0x6666666666666666666666666666666666666666",
    },
    markets: [{ ...manifest.markets[0], portfolioMarketIndex: 0 }],
  };
  const adapter = {
    async getChainId() { return 1; },
    async getHeadBlockNumber() { return 0; },
    async getBlock() { throw new Error("not reached"); },
    async getEvents() { return []; },
    async getMarkTicks() { return { "ETH-PERP": 100 }; },
  };
  await assert.rejects(
    () => syncOperatorOnce(portfolioManifest, new ReferenceIndexer(1), adapter),
    /requires getPortfolioHealth/,
  );
});

test("keeper execution always simulates before submission", async () => {
  const tasks = [
    { kind: "executeConditional", marketId: "ETH-PERP", orderId: 1n },
    { kind: "executeConditional", marketId: "ETH-PERP", orderId: 2n },
  ] as const;
  const calls: string[] = [];

  const submitted = await executeKeeperTasks(tasks, {
    async simulate(task) {
      calls.push(`simulate:${task.orderId}`);
      return task.orderId === 2n;
    },
    async submit(task) {
      calls.push(`submit:${task.orderId}`);
      return `tx-${task.orderId}`;
    },
  });

  assert.deepEqual(calls, ["simulate:1", "simulate:2", "submit:2"]);
  assert.deepEqual(submitted, [{
    task: tasks[1],
    transactionId: "tx-2",
  }]);
});

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  ReferenceIndexer,
  executeKeeperTasksIdempotent,
  keeperTaskId,
  runOperatorCycle,
  syncOperatorOnce,
  type NormalizedEvent,
  type OperatorManifest,
} from "../dist/index.js";
import { JsonFileCheckpointStore } from "../dist/node.js";

const CORE = "0x1111111111111111111111111111111111111111";
const ADV = "0x2222222222222222222222222222222222222222";
const ALICE = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

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

function conditionalEvent(blockNumber: number, hash: string): NormalizedEvent {
  return {
    chainId: 1,
    blockNumber,
    transactionIndex: 0,
    logIndex: 0,
    blockHash: hash,
    address: ADV,
    marketId: "ETH-PERP",
    name: "ConditionalOrderPlaced",
    args: {
      orderId: 7n,
      owner: ALICE,
      triggerAboveOrEqual: true,
      triggerTick: 100,
    },
  };
}

function linearAdapter(head: number) {
  return {
    async getChainId() { return 1; },
    async getHeadBlockNumber() { return head; },
    async getBlock(number: number) {
      return {
        number,
        hash: `0x${number.toString(16)}`,
        parentHash: number === 1 ? "0x0" : `0x${(number - 1).toString(16)}`,
      };
    },
    async getEvents(block: { number: number; hash: string }) {
      return block.number === 1 ? [conditionalEvent(1, block.hash)] : [];
    },
    async getMarkTicks() { return { "ETH-PERP": 110 }; },
    async getTimestamp() { return 100n; },
  };
}

test("sync respects confirmation depth and bounded catch-up batches", async () => {
  const indexer = new ReferenceIndexer(1);
  const result = await syncOperatorOnce(
    manifest,
    indexer,
    linearAdapter(6),
    { confirmationDepth: 2, maxBlocksPerSync: 2 },
  );

  assert.equal(result.remoteHead, 6);
  assert.equal(result.safeHead, 4);
  assert.equal(result.fromBlock, 1);
  assert.equal(result.toBlock, 2);
  assert.equal(result.appliedBlocks, 2);
  assert.equal(indexer.headBlock()?.number, 2);
});

test("bounded catch-up continues from the persisted head", async () => {
  const indexer = new ReferenceIndexer(1);
  const adapter = linearAdapter(6);

  await syncOperatorOnce(
    manifest,
    indexer,
    adapter,
    { confirmationDepth: 2, maxBlocksPerSync: 2 },
  );
  const second = await syncOperatorOnce(
    manifest,
    indexer,
    adapter,
    { confirmationDepth: 2, maxBlocksPerSync: 2 },
  );

  assert.equal(second.fromBlock, 3);
  assert.equal(second.toBlock, 4);
  assert.equal(second.appliedBlocks, 2);
  assert.equal(indexer.headBlock()?.number, 4);
});

test("keeper idempotency keys are stable and suppress duplicate submission", async () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0x1", parentHash: "0x0" },
    [conditionalEvent(1, "0x1")],
  );
  const task = {
    kind: "executeConditional",
    marketId: "ETH-PERP",
    orderId: 7n,
  } as const;
  const expectedId = keeperTaskId(manifest, indexer.branchEpoch(), task);
  assert.equal(expectedId, keeperTaskId(manifest, indexer.branchEpoch(), task));

  const seen = new Set<string>();
  const submissions: string[] = [];
  const executor = {
    async simulate() { return true; },
    async alreadySubmitted(key: string) { return seen.has(key); },
    async submit(_task: typeof task, key: string) {
      seen.add(key);
      submissions.push(key);
      return "0xtx";
    },
  };

  const first = await executeKeeperTasksIdempotent(
    manifest,
    indexer.branchEpoch(),
    [task],
    executor,
  );
  const second = await executeKeeperTasksIdempotent(
    manifest,
    indexer.branchEpoch(),
    [task],
    executor,
  );

  assert.equal(first.length, 1);
  assert.equal(first[0].idempotencyKey, expectedId);
  assert.deepEqual(second, []);
  assert.deepEqual(submissions, [expectedId]);
});

test("atomic JSON checkpoint store restores a restarted operator cycle", async () => {
  const dir = await mkdtemp(join(tmpdir(), "order-book-operator-"));
  const path = join(dir, "state", "checkpoint.json");
  try {
    const store = new JsonFileCheckpointStore(path);
    const adapter = linearAdapter(2);

    const firstIndexer = new ReferenceIndexer(1);
    const first = await runOperatorCycle(
      manifest,
      firstIndexer,
      adapter,
      store,
      undefined,
      { maxBlocksPerSync: 1 },
    );
    assert.equal(first.restoredCheckpoint, false);
    assert.equal(firstIndexer.headBlock()?.number, 1);

    const raw = JSON.parse(await readFile(path, "utf8"));
    assert.ok(raw.manifestIdentity);
    assert.equal(raw.checkpoint.head.number, 1);

    const restarted = new ReferenceIndexer(1);
    const second = await runOperatorCycle(
      manifest,
      restarted,
      adapter,
      store,
      undefined,
      { maxBlocksPerSync: 1 },
    );
    assert.equal(second.restoredCheckpoint, true);
    assert.equal(second.fromBlock, 2);
    assert.equal(restarted.headBlock()?.number, 2);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("checkpoint files fail closed across deployment identities", async () => {
  const dir = await mkdtemp(join(tmpdir(), "order-book-operator-"));
  const path = join(dir, "checkpoint.json");
  try {
    const store = new JsonFileCheckpointStore(path);
    const indexer = new ReferenceIndexer(1);
    indexer.applyBlock({ number: 1, hash: "0x1", parentHash: "0x0" }, []);
    const identity = "deployment-a";
    await store.save(identity, indexer.checkpoint(manifest));

    await assert.rejects(
      () => store.load("deployment-b"),
      /does not match manifest identity/,
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});


test("keeper idempotency stays stable across ordinary head advances and changes after reorg", async () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0x1", parentHash: "0x0" },
    [conditionalEvent(1, "0x1")],
  );
  const task = {
    kind: "executeConditional",
    marketId: "ETH-PERP",
    orderId: 7n,
  } as const;

  const first = keeperTaskId(manifest, indexer.branchEpoch(), task);
  indexer.applyBlock({ number: 2, hash: "0x2a", parentHash: "0x1" }, []);
  const advanced = keeperTaskId(manifest, indexer.branchEpoch(), task);
  assert.equal(advanced, first);

  indexer.rollbackTo(1);
  indexer.applyBlock({ number: 2, hash: "0x2b", parentHash: "0x1" }, []);
  const replacement = keeperTaskId(manifest, indexer.branchEpoch(), task);
  assert.notEqual(replacement, first);
});

test("sync rejects an indexed checkpoint ahead of the configured safe head", async () => {
  const indexer = new ReferenceIndexer(1);
  const adapter = linearAdapter(6);
  await syncOperatorOnce(manifest, indexer, adapter, {
    confirmationDepth: 0,
    maxBlocksPerSync: 6,
  });
  assert.equal(indexer.headBlock()?.number, 6);

  await assert.rejects(
    () => syncOperatorOnce(manifest, indexer, adapter, {
      confirmationDepth: 2,
      maxBlocksPerSync: 2,
    }),
    /ahead of configured safe head/,
  );
  assert.equal(indexer.headBlock()?.number, 6);
});

test("checkpoint persists canonical branch epoch across restart", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 1, hash: "0x1", parentHash: "0x0" },
    [conditionalEvent(1, "0x1")],
  );
  indexer.applyBlock({ number: 2, hash: "0x2a", parentHash: "0x1" }, []);
  indexer.rollbackTo(1);
  indexer.applyBlock({ number: 2, hash: "0x2b", parentHash: "0x1" }, []);

  const checkpoint = indexer.checkpoint(manifest);
  assert.equal(checkpoint.branchEpoch, 1);

  const restored = new ReferenceIndexer(1);
  restored.restoreCheckpoint(checkpoint, manifest);
  assert.equal(restored.branchEpoch(), 1);
});

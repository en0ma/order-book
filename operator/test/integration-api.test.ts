import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  ReferenceIndexer,
  type OperatorManifest,
} from "../dist/index.js";
import {
  normalizeCanonicalEvent,
} from "../dist/integration.js";
import {
  buildApiSnapshot,
  buildOperatorDiagnostics,
  tasksEnvelope,
} from "../dist/api.js";
import {
  JsonlOperatorAuditJournal,
} from "../dist/node.js";

const CORE = "0x1111111111111111111111111111111111111111";
const ADV = "0x2222222222222222222222222222222222222222";
const MM = "0x3333333333333333333333333333333333333333";
const ORACLE = "0x4444444444444444444444444444444444444444";
const TOKEN = "0x5555555555555555555555555555555555555555";
const ALICE = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

const manifest: OperatorManifest = {
  schemaVersion: 1,
  chainId: 1,
  deploymentBlock: 100,
  collateral: { token: TOKEN, decimals: 18 },
  markets: [{
    id: "ETH-PERP",
    core: CORE,
    advanced: ADV,
    marketMaker: MM,
    oracle: ORACLE,
  }],
};

test("canonical decoded events normalize into operator lifecycle inputs", () => {
  const liquidity = normalizeCanonicalEvent(manifest, {
    chainId: 1,
    blockNumber: 100,
    blockHash: "0x100",
    transactionIndex: 0,
    logIndex: 0,
    address: CORE,
    event: {
      name: "LiquidityAdded",
      maker: ALICE,
      side: 1,
      tick: 105,
      lots: 10n,
      generation: 3,
    },
  });
  assert.equal(liquidity.marketId, "ETH-PERP");
  assert.deepEqual(liquidity.args, {
    account: ALICE,
    side: 1,
    tick: 105,
    lots: 10n,
    generation: 3,
  });

  const conditional = normalizeCanonicalEvent(manifest, {
    chainId: 1,
    blockNumber: 100,
    blockHash: "0x100",
    transactionIndex: 0,
    logIndex: 1,
    address: ADV,
    event: {
      name: "ConditionalOrderPlaced",
      orderId: 7n,
      owner: ALICE,
      side: 0,
      triggerTick: 110,
      triggerAboveOrEqual: true,
    },
  });
  assert.deepEqual(conditional.args, {
    orderId: 7n,
    owner: ALICE,
    side: 0,
    triggerTick: 110,
    triggerAboveOrEqual: true,
  });
});

test("normalizer rejects wrong-chain and unexpected emitters", () => {
  assert.throws(
    () => normalizeCanonicalEvent(manifest, {
      chainId: 2,
      blockNumber: 100,
      blockHash: "0x100",
      transactionIndex: 0,
      logIndex: 0,
      address: CORE,
      event: { name: "Trade", taker: ALICE, takerSide: 0, tick: 100, lots: 1n },
    }),
    /chainId/,
  );
  assert.throws(
    () => normalizeCanonicalEvent(manifest, {
      chainId: 1,
      blockNumber: 100,
      blockHash: "0x100",
      transactionIndex: 0,
      logIndex: 0,
      address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      event: { name: "Trade", taker: ALICE, takerSide: 0, tick: 100, lots: 1n },
    }),
    /core event came from unexpected address/,
  );
  assert.throws(
    () => normalizeCanonicalEvent(manifest, {
      chainId: 1,
      blockNumber: 100,
      blockHash: "0x100",
      transactionIndex: 0,
      logIndex: 1,
      address: CORE,
      event: {
        name: "ConditionalOrderPlaced",
        orderId: 1n,
        owner: ALICE,
        side: 0,
        triggerTick: 100,
        triggerAboveOrEqual: true,
      },
    }),
    /advanced event came from unexpected address/,
  );
});

test("API snapshot and diagnostics are JSON-safe and expose catch-up health", () => {
  const indexer = new ReferenceIndexer(1);
  indexer.applyBlock(
    { number: 100, hash: "0x100", parentHash: "0x099" },
    [
      normalizeCanonicalEvent(manifest, {
        chainId: 1,
        blockNumber: 100,
        blockHash: "0x100",
        transactionIndex: 0,
        logIndex: 0,
        address: CORE,
        event: {
          name: "LiquidityAdded",
          maker: ALICE,
          side: 1,
          tick: 105,
          lots: 10n,
          generation: 0,
        },
      }),
    ],
  );

  const snapshot = buildApiSnapshot(manifest, indexer);
  assert.doesNotThrow(() => JSON.stringify(snapshot));
  assert.deepEqual(snapshot.pools, [{
    key: "ETH-PERP:1:105",
    remainingLots: "10",
    generation: 0,
  }]);

  const diagnostics = buildOperatorDiagnostics(indexer, {
    fromBlock: 101,
    toBlock: 101,
    remoteHead: 103,
    safeHead: 103,
    appliedBlocks: 1,
    tasks: [{ kind: "executeConditional", marketId: "ETH-PERP", orderId: 7n }],
  });
  assert.equal(diagnostics.status, "catching_up");
  assert.equal(diagnostics.lagBlocks, 3);
  assert.equal(diagnostics.taskCounts.executeConditional, 1);

  const envelope = tasksEnvelope(manifest, indexer, [
    { kind: "executeConditional", marketId: "ETH-PERP", orderId: 7n },
  ]);
  assert.doesNotThrow(() => JSON.stringify(envelope));
  assert.deepEqual(envelope.payload, {
    tasks: [{ kind: "executeConditional", marketId: "ETH-PERP", orderId: "7" }],
  });
});

test("append-only operator audit journal persists JSONL records", async () => {
  const dir = await mkdtemp(join(tmpdir(), "order-book-operator-"));
  const path = join(dir, "audit.jsonl");
  const journal = new JsonlOperatorAuditJournal(path);

  await journal.append({
    timestamp: "2026-10-06T12:00:00.000Z",
    manifestIdentity: "chain:1|deployment:100",
    kind: "cycle",
    payload: { safeHead: 100, appliedBlocks: 2 },
  });
  await journal.append({
    timestamp: "2026-10-06T12:00:01.000Z",
    manifestIdentity: "chain:1|deployment:100",
    kind: "submission",
    payload: { idempotencyKey: "abc", tx: "0x123" },
  });

  const lines = (await readFile(path, "utf8")).trim().split("\n").map(JSON.parse);
  assert.equal(lines.length, 2);
  assert.equal(lines[0].kind, "cycle");
  assert.equal(lines[1].payload.idempotencyKey, "abc");
});


test("API surfaces reject manifest/indexer chain mismatch", () => {
  const wrongChainIndexer = new ReferenceIndexer(2);
  assert.throws(
    () => buildApiSnapshot(manifest, wrongChainIndexer),
    /manifest chainId does not match indexer/,
  );
  assert.throws(
    () => tasksEnvelope(manifest, wrongChainIndexer, []),
    /manifest chainId does not match indexer/,
  );
});

test("audit journal recursively serializes bigint payloads", async () => {
  const dir = await mkdtemp(join(tmpdir(), "order-book-operator-bigint-"));
  const path = join(dir, "audit.jsonl");
  const journal = new JsonlOperatorAuditJournal(path);

  await journal.append({
    timestamp: "2026-10-06T12:00:02.000Z",
    manifestIdentity: "chain:1|deployment:100",
    kind: "submission",
    payload: {
      task: {
        kind: "liquidationCandidate",
        orderId: 7n,
        conditionalIds: [1n, 2n],
        nested: { trailingIds: [3n] },
      },
    },
  });

  const [record] = (await readFile(path, "utf8")).trim().split("\n").map(JSON.parse);
  assert.equal(record.payload.task.orderId, "7");
  assert.deepEqual(record.payload.task.conditionalIds, ["1", "2"]);
  assert.deepEqual(record.payload.task.nested.trailingIds, ["3"]);
});

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { ReferenceIndexer } from "../dist/index.js";
import {
  HttpJsonRpcClient,
  JsonFileCheckpointStore,
  ReferenceNodeService,
} from "../dist/node.js";

const CORE = "0x0000000000000000000000000000000000000011";
const ADVANCED = "0x0000000000000000000000000000000000000012";
const ORACLE = "0x0000000000000000000000000000000000000013";
const TOKEN = "0x0000000000000000000000000000000000000014";

const manifest = {
  schemaVersion: 1,
  chainId: 1,
  deploymentBlock: 10,
  packageVersion: "test",
  collateral: { token: TOKEN, decimals: 18 },
  markets: [
    {
      id: "ETH-PERP",
      core: CORE,
      advanced: ADVANCED,
      oracle: ORACLE,
      scales: { collateralUnitsPerLotTick: "1" },
      parameters: {
        executionBandTicks: 40,
        initialMarginBps: 1000,
        takerFeeBps: 0,
        makerRebateBps: 0,
      },
    },
  ],
};

function hex(value) {
  return `0x${value.toString(16)}`;
}

function rawLog(block, tx, log, data) {
  return {
    address: CORE,
    blockNumber: hex(block.number),
    blockHash: block.hash,
    transactionIndex: hex(tx),
    logIndex: hex(log),
    topics: [],
    data,
  };
}

function jsonResponse(result) {
  return {
    ok: true,
    status: 200,
    async text() {
      return JSON.stringify({ jsonrpc: "2.0", id: 1, result });
    },
  };
}

function createRpcFixture() {
  const blocks = new Map([
    [10, { number: hex(10), hash: "0xaaa10", parentHash: "0xaaa09" }],
    [11, { number: hex(11), hash: "0xaaa11", parentHash: "0xaaa10" }],
  ]);
  const logs = new Map([
    [10, [rawLog(blocks.get(10), 0, 0, "0x01")]],
    [11, [rawLog(blocks.get(11), 0, 0, "0x02")]],
  ]);

  const fetch = async (_url, init) => {
    const request = JSON.parse(init.body);
    switch (request.method) {
      case "eth_chainId":
        return jsonResponse("0x1");
      case "eth_blockNumber":
        return jsonResponse(hex(Math.max(...blocks.keys())));
      case "eth_getBlockByNumber": {
        const number = Number.parseInt(request.params[0].slice(2), 16);
        return jsonResponse(blocks.get(number) ?? null);
      }
      case "eth_getLogs": {
        const number = Number.parseInt(request.params[0].fromBlock.slice(2), 16);
        return jsonResponse(logs.get(number) ?? []);
      }
      default:
        throw new Error(`unexpected RPC method ${request.method}`);
    }
  };

  return { blocks, logs, fetch };
}

function decoder(log) {
  if (log.data === "0x01") {
    return {
      name: "LiquidityAdded",
      side: 0,
      tick: 100,
      lots: 10n,
      generation: 1,
    };
  }
  if (log.data === "0x02") {
    return { name: "Trade", takerSide: 1, tick: 100, lots: 4n };
  }
  if (log.data === "0x03") {
    return { name: "Trade", takerSide: 1, tick: 100, lots: 7n };
  }
  return undefined;
}

test("node service syncs JSON-RPC blocks and persists restart-safe checkpoints", async () => {
  const dir = await mkdtemp(join(tmpdir(), "order-book-indexer-"));
  try {
    const fixture = createRpcFixture();
    const rpc = new HttpJsonRpcClient("http://rpc.test", { fetch: fixture.fetch });
    const store = new JsonFileCheckpointStore(join(dir, "checkpoint.json"));
    const service = await ReferenceNodeService.create(manifest, rpc, decoder, store);

    await service.syncTo(10);
    assert.deepEqual(service.indexer.head(), { number: 10, hash: "0xaaa10" });
    assert.equal(
      service.indexer.snapshotState().pools["ETH-PERP:0:100"].remainingLots,
      "10",
    );

    const checkpoint = JSON.parse(await readFile(store.path, "utf8"));
    assert.equal(checkpoint.cursor.number, 10);

    const restarted = await ReferenceNodeService.create(manifest, rpc, decoder, store);
    await restarted.syncTo(11);
    assert.deepEqual(restarted.indexer.head(), { number: 11, hash: "0xaaa11" });
    assert.equal(
      restarted.indexer.snapshotState().pools["ETH-PERP:0:100"].remainingLots,
      "6",
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("node service rolls back a retained orphan and replays the canonical replacement", async () => {
  const dir = await mkdtemp(join(tmpdir(), "order-book-reorg-"));
  try {
    const fixture = createRpcFixture();
    const rpc = new HttpJsonRpcClient("http://rpc.test", { fetch: fixture.fetch });
    const store = new JsonFileCheckpointStore(join(dir, "checkpoint.json"));
    const service = await ReferenceNodeService.create(
      manifest,
      rpc,
      decoder,
      store,
      { maxReorgDepth: 8 },
    );

    await service.syncTo(11);
    assert.equal(
      service.indexer.snapshotState().pools["ETH-PERP:0:100"].remainingLots,
      "6",
    );

    const replacement = {
      number: hex(11),
      hash: "0xbbb11",
      parentHash: "0xaaa10",
    };
    fixture.blocks.set(11, replacement);
    fixture.logs.set(11, [rawLog(replacement, 0, 0, "0x03")]);

    await service.syncTo(11);

    assert.deepEqual(service.indexer.head(), { number: 11, hash: "0xbbb11" });
    assert.equal(
      service.indexer.snapshotState().pools["ETH-PERP:0:100"].remainingLots,
      "3",
    );

    const checkpoint = JSON.parse(await readFile(store.path, "utf8"));
    assert.equal(checkpoint.cursor.hash, "0xbbb11");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("node service rejects an RPC connected to the wrong chain", async () => {
  const fetch = async () => jsonResponse("0x2");
  const rpc = new HttpJsonRpcClient("http://rpc.test", { fetch });
  const dir = await mkdtemp(join(tmpdir(), "order-book-chain-"));

  try {
    await assert.rejects(
      ReferenceNodeService.create(
        manifest,
        rpc,
        decoder,
        new JsonFileCheckpointStore(join(dir, "checkpoint.json")),
      ),
      /does not match manifest chainId/,
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("rollback cursor API is bounded to retained indexer history", () => {
  const indexer = new ReferenceIndexer(manifest, { maxReorgDepth: 2 });
  indexer.applyBlock({
    chainId: 1,
    number: 10,
    hash: "0x10",
    parentHash: "0x09",
    logs: [],
  });
  indexer.applyBlock({
    chainId: 1,
    number: 11,
    hash: "0x11",
    parentHash: "0x10",
    logs: [],
  });
  indexer.applyBlock({
    chainId: 1,
    number: 12,
    hash: "0x12",
    parentHash: "0x11",
    logs: [],
  });

  assert.deepEqual(indexer.retainedBlocks(), [
    { number: 10, hash: "0x10" },
    { number: 11, hash: "0x11" },
    { number: 12, hash: "0x12" },
  ]);

  indexer.applyBlock({
    chainId: 1,
    number: 13,
    hash: "0x13",
    parentHash: "0x12",
    logs: [],
  });

  assert.deepEqual(indexer.retainedBlocks(), [
    { number: 11, hash: "0x11" },
    { number: 12, hash: "0x12" },
    { number: 13, hash: "0x13" },
  ]);
  assert.throws(
    () => indexer.rollbackTo({ number: 10, hash: "0x10" }),
    /rollback checkpoint unavailable/,
  );
});

test("restart preserves retained history and recovers a short reorg", async () => {
  const dir = await mkdtemp(join(tmpdir(), "order-book-restart-reorg-"));
  try {
    const fixture = createRpcFixture();
    const rpc = new HttpJsonRpcClient("http://rpc.test", { fetch: fixture.fetch });
    const store = new JsonFileCheckpointStore(join(dir, "checkpoint.json"));

    const first = await ReferenceNodeService.create(
      manifest,
      rpc,
      decoder,
      store,
      { maxReorgDepth: 8 },
    );
    await first.syncTo(11);

    const restarted = await ReferenceNodeService.create(
      manifest,
      rpc,
      decoder,
      store,
      { maxReorgDepth: 8 },
    );
    assert.deepEqual(restarted.indexer.retainedBlocks(), [
      { number: 10, hash: "0xaaa10" },
      { number: 11, hash: "0xaaa11" },
    ]);

    const replacement = {
      number: hex(11),
      hash: "0xbbb11",
      parentHash: "0xaaa10",
    };
    fixture.blocks.set(11, replacement);
    fixture.logs.set(11, [rawLog(replacement, 0, 0, "0x03")]);

    await restarted.syncTo(11);

    assert.deepEqual(restarted.indexer.head(), {
      number: 11,
      hash: "0xbbb11",
    });
    assert.equal(
      restarted.indexer.snapshotState().pools["ETH-PERP:0:100"].remainingLots,
      "3",
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("node service rejects a chain switch between sync calls", async () => {
  const fixture = createRpcFixture();
  let chainId = 1;
  const fetch = async (url, init) => {
    const request = JSON.parse(init.body);
    if (request.method === "eth_chainId") {
      return jsonResponse(hex(chainId));
    }
    return fixture.fetch(url, init);
  };

  const dir = await mkdtemp(join(tmpdir(), "order-book-chain-switch-"));
  try {
    const rpc = new HttpJsonRpcClient("http://rpc.test", { fetch });
    const store = new JsonFileCheckpointStore(join(dir, "checkpoint.json"));
    const service = await ReferenceNodeService.create(manifest, rpc, decoder, store);

    await service.syncTo(10);
    const before = service.indexer.head();

    chainId = 2;
    await assert.rejects(
      service.syncTo(11),
      /does not match manifest chainId/,
    );
    assert.deepEqual(service.indexer.head(), before);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});


import test from "node:test";
import assert from "node:assert/strict";
import { createHttpRuntime } from "../dist/http.js";
import { composeReadModel } from "../dist/read-model.js";
const owner = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const snapshot = {
  version: 1, chainId: 1, head: { number: 20, hash: "0xcanonical" },
  pools: [{ key: "ETH:0:100", remainingLots: "10", generation: 1 }],
  conditionals: [], trailing: [], managedQuotes: [], portfolioLocks: [],
};
const model = composeReadModel(snapshot, { version: 1, records: [{
  key: JSON.stringify(["ETH", "1"]), marketId: "ETH", strategyId: "1",
  owner, kind: "iceberg", totalLots: "100", placedAtBlock: 20,
}] });
async function withServer(options, fn) {
  const runtime = createHttpRuntime({ snapshot: () => model, markets: ["ETH"], ...options });
  await runtime.listen(0);
  const address = runtime.server.address();
  try { await fn("http://127.0.0.1:" + address.port); }
  finally { await runtime.close(); }
}
test("HTTP routes expose canonical head, health, markets, and bounded book reads", async () => {
  await withServer({}, async base => {
    const markets = await fetch(base + "/markets");
    assert.equal(markets.status, 200);
    assert.equal(markets.headers.get("x-canonical-head"), "0xcanonical");
    assert.deepEqual((await markets.json()).markets, ["ETH"]);
    const book = await fetch(base + "/markets/ETH/book?depth=1");
    assert.equal((await book.json()).levels[0].remainingLots, "10");
    assert.equal((await fetch(base + "/markets/ETH/book?depth=500")).status, 400);
    assert.equal((await fetch(base + "/markets/%/book")).status, 400);
    assert.equal((await fetch(base + "/health")).status, 200);
  });
});
test("HTTP account reads fail closed without caller-supplied authorization", async () => {
  await withServer({}, async base => {
    assert.equal((await fetch(base + "/accounts/" + owner)).status, 403);
    assert.equal((await fetch(base + "/accounts/" + owner, { method: "POST" })).status, 405);
  });
  await withServer({ authorizeAccount: request => request.headers.authorization === "Bearer test" }, async base => {
    assert.equal((await fetch(base + "/accounts/" + owner)).status, 403);
    const allowed = await fetch(base + "/accounts/" + owner, { headers: { authorization: "Bearer test" } });
    assert.equal(allowed.status, 200);
    assert.equal((await allowed.json()).strategies.items.length, 1);
  });
});
test("HTTP rejects oversized, duplicate, and unknown parameters", async () => {
  await withServer({ maxQueryBytes: 40 }, async base => {
    assert.equal((await fetch(base + "/strategies?limit=1&limit=2")).status, 400);
    assert.equal((await fetch(base + "/strategies?unknown=1")).status, 400);
    assert.equal((await fetch(base + "/strategies?cursor=" + "a".repeat(50))).status, 414);
    assert.equal((await fetch(base + "/strategies", { method: "HEAD" })).status, 200);
  });
});
test("HTTP refuses unavailable canonical snapshots and failed providers", async () => {
  await withServer({ snapshot: () => ({ ...model, snapshot: { ...snapshot, head: undefined } }) }, async base => {
    assert.equal((await fetch(base + "/markets")).status, 503);
  });
  await withServer({ snapshot: () => { throw new Error("RPC unavailable"); } }, async base => {
    assert.equal((await fetch(base + "/markets")).status, 503);
  });
});

test("stalled provider and authorization awaits terminate with 503", async () => {
  await withServer({ requestTimeoutMs: 30, snapshot: () => new Promise(() => {}) }, async base => {
    const start = Date.now();
    const result = await fetch(base + "/markets");
    assert.equal(result.status, 503);
    assert.ok(Date.now() - start < 2000);
  });
  await withServer({
    requestTimeoutMs: 30,
    authorizeAccount: () => new Promise(() => {}),
  }, async base => {
    const start = Date.now();
    const result = await fetch(base + "/accounts/" + owner);
    assert.equal(result.status, 503);
    assert.ok(Date.now() - start < 2000);
  });
});

test("HTTP bounds concurrent upstream reads and recovers slots after completion", async () => {
  let release;
  let started;
  const entered = new Promise(resolve => { started = resolve; });
  const blocked = new Promise(resolve => { release = resolve; });
  const runtime = createHttpRuntime({
    markets: ["ETH"], maxConcurrentRequests: 1,
    snapshot: async () => { started(); await blocked; return model; },
  });
  await runtime.listen(0);
  const address = runtime.server.address();
  const base = "http://127.0.0.1:" + address.port;
  try {
    const first = fetch(base + "/markets");
    await entered;
    const second = await fetch(base + "/markets");
    assert.equal(second.status, 503);
    assert.equal((await second.json()).error, "capacity_exceeded");
    assert.equal(runtime.metrics().rejected, 1);
    release();
    assert.equal((await first).status, 200);
    assert.equal((await fetch(base + "/markets")).status, 200);
  } finally { release(); await runtime.close(); }
});
test("HTTP telemetry redacts account identifiers and isolates observer failures", async () => {
  const reports = [];
  const runtime = createHttpRuntime({
    markets: ["ETH"], snapshot: () => model,
    authorizeAccount: () => true,
    onRequest: result => { reports.push(result); throw new Error("observer down"); },
  });
  await runtime.listen(0);
  const address = runtime.server.address();
  try {
    const base = "http://127.0.0.1:" + address.port;
    assert.equal((await fetch(base + "/accounts/" + owner)).status, 200);
    assert.equal((await fetch(base + "/markets")).status, 200);
    assert.equal(runtime.metrics().total, 2);
    assert.equal(runtime.metrics().active, 0);
    assert.ok(reports.some(r => r.route === "/accounts/:address" && r.status === 200));
    assert.ok(reports.every(r => !JSON.stringify(r).includes(owner)));
  } finally { await runtime.close(); }
});

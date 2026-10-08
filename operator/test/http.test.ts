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

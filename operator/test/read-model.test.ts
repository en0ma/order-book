import test from "node:test";
import assert from "node:assert/strict";
import { composeReadModel, marketBook, routeRead } from "../dist/read-model.js";
const owner = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const snapshot = {
  version: 1, chainId: 1, head: { number: 100, hash: "0x1234" },
  pools: [
    { key: "ETH:0:10", remainingLots: "5", generation: 1 },
    { key: "ETH:0:20", remainingLots: "7", generation: 1 },
    { key: "ETH:1:30", remainingLots: "10", generation: 1 },
    { key: "ETH:1:25", remainingLots: "2", generation: 1 },
    { key: "BTC:1:40", remainingLots: "12", generation: 1 },
    { key: "ETH:0:22", remainingLots: "0", generation: 1 },
  ], conditionals: [], trailing: [], managedQuotes: [],
  portfolioLocks: [{ account: owner, equity: "20", requirement: "5", lockedCollateral: "5" }],
};
const record = (id: string) => ({
  key: JSON.stringify(["ETH", id]), marketId: "ETH", strategyId: id,
  owner, kind: "iceberg", placedAtBlock: 100, totalLots: "100",
});
const model = composeReadModel(snapshot, { version: 1, records: [record("1"), record("2"), record("3")] });
test("book uses price ordering, true market filtering, and per-side bounds", () => {
  assert.deepEqual(marketBook(model, "ETH", 1).levels.map(x => x.key), ["ETH:0:20", "ETH:1:25"]);
  assert.deepEqual(marketBook(model, "ETH", 2).levels.map(x => x.key),
    ["ETH:0:20", "ETH:0:10", "ETH:1:25", "ETH:1:30"]);
  assert.throws(() => marketBook(model, "ETH", 101), /depth/);
});
test("route surfaces bounded strategy pagination and account collateral", () => {
  const first = routeRead(model, "GET", "/strategies", { limit: "2" });
  assert.equal(first.status, 200);
  assert.equal(first.body.items.length, 2);
  const second = routeRead(model, "GET", "/strategies", { limit: "2", cursor: first.body.nextCursor });
  assert.equal(second.body.items.length, 1);
  const account = routeRead(model, "GET", "/accounts/" + owner, { limit: "1" });
  assert.equal(account.body.portfolioLock.equity, "20");
  assert.equal(account.body.strategies.items.length, 1);
});
test("route fails closed for bad limits, missing markets and non-read methods", () => {
  assert.equal(routeRead(model, "GET", "/markets/WRONG/book", {}, ["ETH"]).status, 404);
  assert.equal(routeRead(model, "GET", "/markets/ETH/book", { depth: "100000" }).status, 400);
  assert.equal(routeRead(model, "POST", "/strategies").status, 405);
  assert.equal(routeRead(model, "GET", "/unknown").status, 404);
});
test("read model checks snapshot and diagnostics pairing", () => {
  assert.throws(() => composeReadModel(snapshot, undefined, { headBlock: 99 }), /heads differ/);
  assert.equal(routeRead(model, "GET", "/markets", {}, ["ETH"]).status, 200);
  assert.equal(routeRead(model, "GET", "/health").status, 200);
});

test("pagination cursors reject stale canonical heads and cross-query reuse", () => {
  const first = routeRead(model, "GET", "/strategies", { limit: "1" });
  assert.equal(first.status, 200);
  const cursor = first.body.nextCursor;
  assert.equal(typeof cursor, "string");
  const reorg = composeReadModel({ ...snapshot, head: { number: 100, hash: "0xother" } }, model.strategies);
  assert.equal(routeRead(reorg, "GET", "/strategies", { cursor }).status, 400);
  const advanced = composeReadModel({ ...snapshot, head: { number: 101, hash: "0xnext" } }, model.strategies);
  assert.equal(routeRead(advanced, "GET", "/strategies", { cursor }).status, 400);
  assert.equal(routeRead(model, "GET", "/strategies", { cursor, marketId: "ETH" }).status, 400);
  assert.equal(routeRead(model, "GET", "/strategies", { cursor: "not-json" }).status, 400);
  const accountPage = routeRead(model, "GET", "/accounts/" + owner, { limit: "1" });
  assert.equal(routeRead(model, "GET", "/strategies", { cursor: accountPage.body.strategies.nextCursor }).status, 400);
  assert.equal(routeRead(model, "GET", "/strategies", { cursor }).status, 200);
});
test("invalid URL encoding is a 400, not an internal error", () => {
  assert.equal(routeRead(model, "GET", "/markets/%/book").status, 400);
  assert.equal(routeRead(model, "GET", "/markets/%E0%A4%A/book").status, 400);
});

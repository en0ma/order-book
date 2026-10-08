import test from "node:test";
import assert from "node:assert/strict";
import { checkReadiness } from "../dist/readiness.js";
import { createHttpRuntime } from "../dist/http.js";
const snapshot = { version: 1, chainId: 1, head: { number: 20, hash: "0xabc" },
  pools: [], conditionals: [], trailing: [], managedQuotes: [], portfolioLocks: [] };
const diagnostics = { status: "healthy", headBlock: 20, remoteHead: 20, safeHead: 20,
  lagBlocks: 0, appliedBlocks: 0, taskCounts: {}, activeConditionals: 0,
  activeTrailing: 0, managedQuotes: 0, portfolioAccounts: 0 };
test("readiness fails closed on missing diagnostics and divergent heads", () => {
  assert.equal(checkReadiness(snapshot).reason, "missing_diagnostics");
  assert.equal(checkReadiness({ ...snapshot, head: undefined }, diagnostics).reason, "missing_head");
  assert.equal(checkReadiness(snapshot, { ...diagnostics, headBlock: 19 }).reason, "head_mismatch");
  assert.equal(checkReadiness(snapshot, diagnostics).ready, true);
  assert.equal(checkReadiness(snapshot, undefined, { requireDiagnostics: false }).ready, true);
});
test("readiness rejects stalled and lagging indexers", () => {
  assert.equal(checkReadiness(snapshot, { ...diagnostics, status: "stalled" }).reason, "stalled");
  assert.equal(checkReadiness(snapshot, { ...diagnostics, safeHead: 25, lagBlocks: 5 }).reason, "lagging");
  assert.equal(checkReadiness(snapshot, { ...diagnostics, safeHead: 25, lagBlocks: 5 }, { maxLagBlocks: 5 }).ready, true);
  assert.throws(() => checkReadiness(snapshot, diagnostics, { maxLagBlocks: -1 }), /lag/);
});
test("HTTP readiness reports 503 and gates data until indexer catches up", async () => {
  let health = { ...diagnostics, status: "stalled" };
  const app = createHttpRuntime({ markets: ["ETH"], readiness: { requireDiagnostics: true },
    snapshot: () => ({ snapshot, diagnostics: health }) });
  await app.listen(0);
  const addr = app.server.address();
  const base = "http://127.0.0.1:" + addr.port;
  try {
    const bad = await fetch(base + "/ready");
    assert.equal(bad.status, 503);
    assert.equal((await bad.json()).reason, "stalled");
    assert.equal((await fetch(base + "/markets")).status, 503);
    health = { ...diagnostics };
    assert.equal((await fetch(base + "/ready")).status, 200);
    assert.equal((await fetch(base + "/markets")).status, 200);
  } finally { await app.close(); }
});

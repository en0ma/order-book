import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSelfHostedOperator } from "../dist/self-hosted.js";
import { JsonFileRecoveryStore } from "../dist/node.js";
const addr = "0x1111111111111111111111111111111111111111";
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 1,
  collateral: { token: addr, decimals: 18 },
  markets: [{ id: "ETH", core: addr, advanced: addr, oracle: addr }] };
const blocks = new Map([
  [1, { number: 1, hash: "0x001", parentHash: "0x000" }],
  [2, { number: 2, hash: "0x002", parentHash: "0x001" }],
]);
function rpc(head = 1) {
  return { getChainId: async () => 1, getHeadBlockNumber: async () => head,
    getBlock: async n => blocks.get(n), getEvents: async () => [],
    getMarkTicks: async () => ({}) };
}
test("durable operator recovers, serves HTTP, and restores canonical bundle after restart", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-recovery-"));
  const config = { bundlePath: join(dir, "bundle.json"), auditPath: join(dir, "audit.jsonl") };
  const first = createSelfHostedOperator(manifest, rpc(), config);
  try {
    await first.http.listen(0);
    const base = "http://127.0.0.1:" + first.http.server.address().port;
    assert.equal((await fetch(base + "/ready")).status, 503);
    const result = await first.recover();
    assert.equal(result.restored, false);
    assert.equal((await fetch(base + "/ready")).status, 200);
    assert.equal((await fetch(base + "/markets")).status, 200);
    const data = JSON.parse(await readFile(config.bundlePath, "utf8"));
    assert.equal(data.bundle.checkpoint.head.hash, "0x001");
    const second = createSelfHostedOperator(manifest, rpc(), config);
    assert.equal(second.publication.ready(), false);
    const restored = await second.recover();
    assert.equal(restored.restored, true);
    assert.equal(second.publication.snapshot().snapshot.head.hash, "0x001");
    assert.match(await readFile(config.auditPath, "utf8"), /"kind":"cycle"/);
  } finally { await first.http.close(); await rm(dir, { recursive: true, force: true }); }
});
test("recovery file rejects foreign identity and corrupt JSON, without replacing the prior bundle", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-recovery-"));
  const path = join(dir, "bundle.json");
  try {
    const store = new JsonFileRecoveryStore(path);
    await assert.rejects(store.save("expected", { identity: "foreign" }), /identity mismatch/);
    assert.equal(await store.load("expected"), undefined);
    await writeFile(path, JSON.stringify({ identity: "foreign", bundle: { identity: "foreign" } }));
    await assert.rejects(store.load("expected"), /identity mismatch/);
    await writeFile(path, "{invalid");
    await assert.rejects(store.load("expected"), SyntaxError);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
test("a canonical reorg after restart closes HTTP and refuses persisted orphan", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-recovery-"));
  const config = { bundlePath: join(dir, "bundle.json") };
  const first = createSelfHostedOperator(manifest, rpc(), config);
  try {
    await first.recover();
    const changed = rpc();
    changed.getBlock = async () => ({ number: 1, hash: "0xfork", parentHash: "0x000" });
    const restarted = createSelfHostedOperator(manifest, changed, config);
    await assert.rejects(restarted.recover(), /not on the canonical branch/);
    assert.equal(restarted.publication.ready(), false);
    assert.throws(() => restarted.publication.snapshot(), /not ready/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

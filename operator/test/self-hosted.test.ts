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

test("recovery bundle syncs newly created nested parent directories", async () => {
  const root = await mkdtemp(join(tmpdir(), "ob-recovery-parent-"));
  const path = join(root, "new", "nested", "bundle.json");
  try {
    const operator = createSelfHostedOperator(manifest, rpc(), { bundlePath: path });
    await operator.recover();
    assert.equal(JSON.parse(await readFile(path, "utf8")).bundle.checkpoint.head.hash, "0x001");
    const restarted = createSelfHostedOperator(manifest, rpc(), { bundlePath: path });
    assert.equal((await restarted.recover()).restored, true);
  } finally { await rm(root, { recursive: true, force: true }); }
});
test("operator rejects an audit path that resolves to the recovery file", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-recovery-alias-"));
  try {
    const file = join(dir, "bundle.json");
    assert.throws(() => createSelfHostedOperator(manifest, rpc(), {
      bundlePath: file, auditPath: join(dir, ".", "bundle.json"),
    }), /audit journal path must differ/);
    assert.throws(() => createSelfHostedOperator(manifest, rpc(), {
      bundlePath: file, auditPath: file,
    }), /audit journal path must differ/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("audit path aliases are rejected before any bundle is written", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-recovery-"));
  try {
    const path = join(dir, "bundle.json");
    assert.throws(() => createSelfHostedOperator(manifest, rpc(), {
      bundlePath: path, auditPath: join(dir, ".", "bundle.json"),
    }), /audit journal path must differ/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
test("recovery store creates nested parents and persists a complete JSON bundle", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-recovery-"));
  const path = join(dir, "nested", "deeper", "bundle.json");
  try {
    const instance = createSelfHostedOperator(manifest, rpc(), { bundlePath: path });
    await instance.recover();
    const loaded = JSON.parse(await readFile(path, "utf8"));
    assert.equal(loaded.bundle.checkpoint.head.hash, "0x001");
    assert.equal(loaded.bundle.strategyHead.hash, "0x001");
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("bootstrap catches up in bounded cycles before HTTP listens", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-bootstrap-"));
  const instance = createSelfHostedOperator(manifest, rpc(2), {
    bundlePath: join(dir, "recovery.json"), sync: { maxBlocksPerSync: 1 },
  });
  try {
    assert.equal(instance.http.server.listening, false);
    const ready = await instance.bootstrap({ maxCycles: 3, listen: { port: 0 } });
    assert.equal(ready.readiness.ready, true);
    assert.equal(ready.head.number, 2);
    assert.equal(instance.http.server.listening, true);
    const base = "http://127.0.0.1:" + instance.http.server.address().port;
    assert.equal((await fetch(base + "/ready")).status, 200);
  } finally {
    if (instance.http.server.listening) await instance.http.close();
    await rm(dir, { recursive: true, force: true });
  }
});
test("bootstrap cycle limits and cancellation prevent HTTP exposure", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-bootstrap-"));
  try {
    const instance = createSelfHostedOperator(manifest, rpc(2), {
      bundlePath: join(dir, "recovery.json"), sync: { maxBlocksPerSync: 1 },
    });
    await assert.rejects(instance.bootstrap({ maxCycles: 1, listen: { port: 0 } }),
      /did not reach canonical readiness/);
    assert.equal(instance.http.server.listening, false);
    assert.equal(instance.publication.ready(), false);
    const stopped = new AbortController();
    stopped.abort();
    await assert.rejects(instance.bootstrap({ signal: stopped.signal, listen: { port: 0 } }),
      /bootstrap aborted/);
    assert.equal(instance.http.server.listening, false);
    await assert.rejects(instance.bootstrap({ maxCycles: 0 }), /invalid maximum/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

import test from "node:test";
import assert from "node:assert/strict";
import { runRecoveryCycle } from "../dist/recovery-cycle.js";
const addr = "0x1111111111111111111111111111111111111111";
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 1,
  collateral: { token: addr, decimals: 18 },
  markets: [{ id: "ETH", core: addr, advanced: addr, oracle: addr }] };
const blocks = new Map([
  [1, { number: 1, hash: "0x001", parentHash: "0x000" }],
  [2, { number: 2, hash: "0x002", parentHash: "0x001" }],
  [3, { number: 3, hash: "0x003", parentHash: "0x002" }],
]);
function harness() {
  let saved;
  let commits = 0;
  let failSave = false;
  const rpc = {
    getChainId: async () => 1,
    getHeadBlockNumber: async () => 3,
    getBlock: async n => blocks.get(n),
    getEvents: async () => [],
    getMarkTicks: async () => ({}),
  };
  const store = {
    load: async () => saved,
    save: async (_, bundle) => { if (failSave) throw new Error("disk full"); saved = bundle; commits++; },
  };
  return { rpc, store, get saved() { return saved; }, get commits() { return commits; },
    setFailSave: v => { failSave = v; } };
}
test("recovery replays canonical blocks and saves index plus strategies atomically", async () => {
  const h = harness();
  const first = await runRecoveryCycle(manifest, h.rpc, h.store, { maxBlocksPerSync: 2 });
  assert.equal(first.appliedBlocks, 2);
  assert.equal(first.readiness.ready, false);
  assert.equal(first.bundle.checkpoint.head.hash, first.bundle.strategyHead.hash);
  const second = await runRecoveryCycle(manifest, h.rpc, h.store);
  assert.equal(second.restored, true);
  assert.equal(second.head.number, 3);
  assert.equal(second.readiness.ready, true);
  assert.equal(h.commits, 2);
});
test("recovery refuses an orphaned checkpoint without publishing or saving", async () => {
  const h = harness();
  await runRecoveryCycle(manifest, h.rpc, h.store, { maxBlocksPerSync: 1 });
  const commits = h.commits;
  const orphan = new Map(blocks);
  orphan.set(1, { number: 1, hash: "0xorphan", parentHash: "0x000" });
  h.rpc.getBlock = async n => orphan.get(n);
  await assert.rejects(() => runRecoveryCycle(manifest, h.rpc, h.store), /not on the canonical branch/);
  assert.equal(h.commits, commits);
});
test("recovery does not expose a new model if atomic persistence fails", async () => {
  const h = harness();
  h.setFailSave(true);
  await assert.rejects(() => runRecoveryCycle(manifest, h.rpc, h.store), /disk full/);
  assert.equal(h.commits, 0);
});
test("recovery rejects RPC chain switch before any checkpoint load", async () => {
  const h = harness();
  h.rpc.getChainId = async () => 2;
  await assert.rejects(() => runRecoveryCycle(manifest, h.rpc, h.store), /chain ID/);
  assert.equal(h.commits, 0);
});

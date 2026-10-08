import test from "node:test";
import assert from "node:assert/strict";
import { createOperatorSupervisor } from "../dist/supervisor.js";
import { createRecoveryPublication } from "../dist/publication.js";
const addr = "0x1111111111111111111111111111111111111111";
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 1,
  collateral: { token: addr, decimals: 18 },
  markets: [{ id: "ETH", core: addr, advanced: addr, oracle: addr }] };
function fixture() {
  let chain = 1, saves = 0, fail = false, stored;
  const rpc = { getChainId: async () => chain, getHeadBlockNumber: async () => 1,
    getBlock: async () => ({ number: 1, hash: "0x001", parentHash: "0x000" }),
    getEvents: async () => [], getMarkTicks: async () => ({}) };
  const store = { load: async () => stored, save: async (_, bundle) => {
    if (fail) throw new Error("storage failed");
    saves++; stored = bundle;
  } };
  const publication = createRecoveryPublication(manifest, rpc, store);
  return { publication, fail: x => { fail = x; }, chain: x => { chain = x; },
    get saves() { return saves; } };
}
function gate() {
  let notify;
  const wait = new Promise(resolve => { notify = resolve; });
  return { wait, release: notify };
}
test("supervisor recovers, admits keeper checks, pauses after failure and recovers again", async () => {
  const h = fixture();
  const events = [];
  const first = gate(), second = gate(), third = gate();
  const supervisor = createOperatorSupervisor(h.publication, {
    intervalMs: 5, maxBackoffMs: 20,
    onCycle: e => {
      events.push(e.kind);
      if (events.length === 1) first.release();
      if (events.length === 2) second.release();
      if (events.length === 3) third.release();
    },
  });
  const running = supervisor.run();
  await first.wait;
  assert.equal(supervisor.status().ready, true);
  const executor = { alreadySubmitted: async () => false,
    simulate: async () => true, submit: async () => "tx" };
  assert.equal((await supervisor.submit([], executor,
    { getCanonicalBlockHash: async () => "0x001" })).admitted, 0);
  h.fail(true);
  await second.wait;
  assert.equal(supervisor.status().ready, false);
  await assert.rejects(supervisor.submit([], executor,
    { getCanonicalBlockHash: async () => "0x001" }), /not ready/);
  h.fail(false);
  await third.wait;
  assert.equal(supervisor.status().ready, true);
  supervisor.stop();
  await running;
  assert.equal(supervisor.status().running, false);
  assert.deepEqual(events.slice(0, 3), ["ready", "error", "ready"]);
});
test("supervisor does not admit keeper work before first cycle or after stop", async () => {
  const h = fixture();
  const supervisor = createOperatorSupervisor(h.publication, { intervalMs: 10 });
  await assert.rejects(supervisor.submit([], {}, {}), /not ready/);
  supervisor.stop();
  await supervisor.run();
  assert.equal(h.saves, 0);
  await assert.rejects(supervisor.submit([], {}, {}), /not ready/);
});
test("bad retry limits fail closed", () => {
  const h = fixture();
  assert.throws(() => createOperatorSupervisor(h.publication, { intervalMs: 0 }), /invalid supervisor/);
  assert.throws(() => createOperatorSupervisor(h.publication, { intervalMs: 10, maxBackoffMs: 2 }), /invalid supervisor/);
});

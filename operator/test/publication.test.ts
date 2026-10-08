import test from "node:test";
import assert from "node:assert/strict";
import { createRecoveryPublication } from "../dist/publication.js";
import { createHttpRuntime } from "../dist/http.js";

const addr = "0x1111111111111111111111111111111111111111";
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 1,
  collateral: { token: addr, decimals: 18 },
  markets: [{ id: "ETH", core: addr, advanced: addr, oracle: addr }] };
const blocks = new Map([[1, { number: 1, hash: "0x001", parentHash: "0x000" }]]);
function setup() {
  let saved;
  let fail = false;
  let remoteHead = 1;
  const rpc = {
    getChainId: async () => 1,
    getHeadBlockNumber: async () => remoteHead,
    getBlock: async number => blocks.get(number),
    getEvents: async () => [],
    getMarkTicks: async () => ({}),
  };
  const store = {
    load: async () => saved,
    save: async (_, bundle) => { if (fail) throw new Error("storage unavailable"); saved = bundle; },
  };
  const publication = createRecoveryPublication(manifest, rpc, store);
  return { rpc, store, publication, fail: value => { fail = value; },
    head: value => { remoteHead = value; } };
}
test("publication stays closed until complete canonical recovery commits", async () => {
  const h = setup();
  assert.equal(h.publication.ready(), false);
  assert.throws(() => h.publication.snapshot(), /not ready/);
  await h.publication.refresh();
  assert.equal(h.publication.ready(), true);
  assert.equal(h.publication.snapshot().snapshot.head.hash, "0x001");
  h.fail(true);
  await assert.rejects(h.publication.refresh(), /storage unavailable/);
  assert.equal(h.publication.ready(), false);
  assert.throws(() => h.publication.snapshot(), /not ready/);
});
test("lagging recovery never exposes stale reads or keeper tasks", async () => {
  const h = setup();
  await h.publication.refresh();
  h.head(2);
  const result = await h.publication.refresh();
  assert.equal(result.readiness.ready, false);
  assert.equal(h.publication.ready(), false);
  await assert.rejects(h.publication.submit([], {}, { getCanonicalBlockHash: async () => "0x001" }), /not ready/);
});
test("HTTP fails closed before first recovery and after persistence failure", async () => {
  const h = setup();
  const server = createHttpRuntime({ snapshot: () => h.publication.snapshot(), markets: ["ETH"],
    readiness: { requireDiagnostics: true, maxLagBlocks: 0 } });
  await server.listen(0);
  const base = "http://127.0.0.1:" + server.server.address().port;
  try {
    assert.equal((await fetch(base + "/ready")).status, 503);
    await h.publication.refresh();
    assert.equal((await fetch(base + "/ready")).status, 200);
    assert.equal((await fetch(base + "/markets")).status, 200);
    h.fail(true);
    await assert.rejects(h.publication.refresh(), /storage unavailable/);
    assert.equal((await fetch(base + "/markets")).status, 503);
  } finally {
    await server.close();
  }
});
test("keeper submission requires a matching canonical head after recovery", async () => {
  const h = setup();
  await h.publication.refresh();
  const executor = { alreadySubmitted: async () => false,
    simulate: async () => true, submit: async () => "tx" };
  const noTasks = await h.publication.submit([], executor,
    { getCanonicalBlockHash: async () => "0x001" });
  assert.equal(noTasks.admitted, 0);
  await assert.rejects(h.publication.submit([], executor,
    { getCanonicalBlockHash: async () => "0xorphan" }), /canonical head hash changed/);
});

import test from "node:test";
import assert from "node:assert/strict";
import { createQuorumRpcAdapter } from "../dist/rpc-quorum.js";
import { createRecoveryPublication } from "../dist/publication.js";
import { createSelfHostedOperator } from "../dist/self-hosted.js";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const addr = "0x1111111111111111111111111111111111111111";
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 1,
  collateral: { token: addr, decimals: 18 },
  markets: [{ id: "ETH", core: addr, advanced: addr, oracle: addr }] };
function source() {
  let hash = "0x001", chainId = 1, head = 1, eventCalls = 0;
  const rpc = {
    getChainId: async () => chainId,
    getHeadBlockNumber: async () => head,
    getBlock: async number => ({ number, hash, parentHash: "0x000" }),
    getEvents: async () => { eventCalls++; return []; },
    getMarkTicks: async () => ({ ETH: 10 }),
  };
  return { rpc, hash: v => { hash = v; }, chain: v => { chainId = v; },
    head: v => { head = v; }, get eventCalls() { return eventCalls; } };
}
test("quorum permits complete recovery when primary and witness agree", async () => {
  const primary = source(), witness = source();
  const rpc = createQuorumRpcAdapter(primary.rpc, [witness.rpc]);
  let saved;
  const store = { load: async () => saved, save: async (_, next) => { saved = next; } };
  const published = createRecoveryPublication(manifest, rpc, store);
  const result = await published.refresh();
  assert.equal(result.readiness.ready, true);
  assert.equal(published.snapshot().snapshot.head.hash, "0x001");
  assert.equal(primary.eventCalls, 1);
  assert.equal((await rpc.verifyBlock(1)).hash, "0x001");
});
test("disagreement closes recovery publication before any new bundle save", async () => {
  const primary = source(), witness = source();
  witness.hash("0xorphan");
  const rpc = createQuorumRpcAdapter(primary.rpc, [witness.rpc]);
  let writes = 0;
  const published = createRecoveryPublication(manifest, rpc, {
    load: async () => undefined, save: async () => { writes++; },
  });
  await assert.rejects(published.refresh(), /hash disagreement/);
  assert.equal(writes, 0);
  assert.equal(published.ready(), false);
  assert.equal(primary.eventCalls, 0);
});
test("quorum uses sufficiently confirmed height and rejects split identity", async () => {
  const primary = source(), witness = source(), third = source();
  primary.head(4); witness.head(2); third.head(3);
  const rpc = createQuorumRpcAdapter(primary.rpc, [witness.rpc, third.rpc], { required: 2 });
  assert.equal(await rpc.getHeadBlockNumber(), 3);
  await assert.rejects(rpc.getBlock(4), /not enough canonical RPC sources/);
  witness.chain(2);
  await assert.rejects(rpc.getChainId(), /chain identity disagreement/);
  assert.throws(() => createQuorumRpcAdapter(primary.rpc, []), /witness/);
});
test("a second witness changes during event reads and recovery fails closed", async () => {
  const primary = source(), witness = source();
  const original = primary.rpc.getEvents;
  primary.rpc.getEvents = async (...args) => {
    const events = await original(...args);
    witness.hash("0xnewfork");
    return events;
  };
  const rpc = createQuorumRpcAdapter(primary.rpc, [witness.rpc]);
  let writes = 0;
  await assert.rejects(createRecoveryPublication(manifest, rpc, {
    load: async () => undefined, save: async () => { writes++; },
  }).refresh(), /hash disagreement/);
  assert.equal(writes, 0);
});
test("self-hosted HTTP remains unavailable on witness disagreement", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-quorum-"));
  const primary = source(), witness = source();
  witness.hash("0xdead");
  const op = createSelfHostedOperator(manifest,
    createQuorumRpcAdapter(primary.rpc, [witness.rpc]), { bundlePath: join(dir, "recovery.json") });
  try {
    await assert.rejects(op.bootstrap({ maxCycles: 1, listen: { port: 0 } }), /hash disagreement/);
    assert.equal(op.http.server.listening, false);
    assert.equal(op.publication.ready(), false);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("keeper checks enforce current RPC quorum even with a primary-only signer verifier", async () => {
  const primary = source(), witness = source();
  const rpc = createQuorumRpcAdapter(primary.rpc, [witness.rpc]);
  let bundle;
  const published = createRecoveryPublication(manifest, rpc, {
    load: async () => bundle, save: async (_, next) => { bundle = next; },
  });
  await published.refresh();
  const executor = { alreadySubmitted: async () => false, simulate: async () => true,
    submit: async () => "tx" };
  const primaryOnly = { getCanonicalBlockHash: async () => "0x001" };
  assert.equal((await published.submit([], executor, primaryOnly)).admitted, 0);
  witness.hash("0xorphan");
  await assert.rejects(published.submit([], executor, primaryOnly), /hash disagreement/);
  assert.equal(published.ready(), true, "the previously published state remains gated by the next refresh");
  await assert.rejects(published.submit([{ kind: "expireConditional", marketId: "ETH", orderId: 1n }],
    executor, primaryOnly), /hash disagreement/);
});
test("self-hosted supervisor keeper admission inherits RPC quorum verification", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-keeper-quorum-"));
  const primary = source(), witness = source();
  const op = createSelfHostedOperator(manifest, createQuorumRpcAdapter(primary.rpc, [witness.rpc]),
    { bundlePath: join(dir, "recovery.json") });
  const controller = new AbortController();
  let firstReady;
  const ready = new Promise(resolve => { firstReady = resolve; });
  const supervisor = op.supervise({ intervalMs: 1000, signal: controller.signal,
    onCycle: event => { if (event.kind === "ready") firstReady(); } });
  const running = supervisor.run();
  try {
    await ready;
    witness.hash("0xnewfork");
    const executor = { alreadySubmitted: async () => false, simulate: async () => true,
      submit: async () => "tx" };
    await assert.rejects(supervisor.submit([], executor, {
      getCanonicalBlockHash: async () => "0x001",
    }), /hash disagreement/);
  } finally {
    supervisor.stop(); controller.abort(); await running;
    await rm(dir, { recursive: true, force: true });
  }
});

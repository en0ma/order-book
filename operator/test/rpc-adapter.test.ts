import test from "node:test";
import assert from "node:assert/strict";
import { createCanonicalRpcAdapter } from "../dist/rpc-adapter.js";
import { createRecoveryPublication } from "../dist/publication.js";
const addr = "0x" + "1".repeat(40);
const H0 = "0x" + "0".repeat(64), H1 = "0x" + "1".repeat(64), H2 = "0x" + "2".repeat(64);
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 1,
  collateral: { token: addr, decimals: 18 },
  markets: [{ id: "ETH", core: addr, advanced: addr, oracle: addr }] };
function fixture() {
  let current = H1, removed = false, wrong = false;
  const methods = [];
  const transport = { async request(method, params) {
    methods.push(method);
    if (method === "eth_chainId") return "0x1";
    if (method === "eth_blockNumber") return "0x1";
    if (method === "eth_getBlockByNumber") return { number: "0x1", hash: current, parentHash: H0 };
    if (method === "eth_getLogs") {
      assert.equal(params[0].fromBlock, "0x1");
      assert.equal(params[0].toBlock, "0x1");
      return [{ address: addr, blockHash: wrong ? H2 : H1, blockNumber: "0x1",
        transactionIndex: "0x0", logIndex: "0x0", topics: ["0x1234"], data: "0x", removed }];
    }
    throw new Error("unexpected RPC " + method);
  } };
  const adapter = createCanonicalRpcAdapter(transport, {
    decode: (log, chainId) => ({ chainId, blockNumber: 1, blockHash: log.blockHash,
      transactionIndex: 0, logIndex: 0, address: addr,
      event: { name: "LiquidityAdded", maker: addr, side: 0, tick: 50, lots: 3n, generation: 1 } }),
    markTicks: async () => ({ ETH: 50 }),
  });
  return { adapter, transport, methods, setHash: v => { current = v; },
    removed: v => { removed = v; }, wrong: v => { wrong = v; } };
}
test("RPC adapter can recover canonical decoded events and publish checkpoint", async () => {
  const h = fixture();
  let bundle;
  const store = { load: async () => bundle, save: async (_, next) => { bundle = next; } };
  const publication = createRecoveryPublication(manifest, h.adapter, store);
  const result = await publication.refresh();
  assert.equal(result.readiness.ready, true);
  assert.equal(result.head.hash, H1);
  assert.equal(publication.snapshot().snapshot.pools.length, 1);
  assert.equal(publication.snapshot().snapshot.pools[0].remainingLots, "3");
  assert.ok(h.methods.includes("eth_getLogs"));
  assert.equal((await h.adapter.getMarkTicks(manifest)).ETH, 50);
});
test("RPC adapter rejects wrong branch, removed logs and post-read reorg", async () => {
  const h = fixture();
  const block = await h.adapter.getBlock(1);
  h.wrong(true);
  await assert.rejects(h.adapter.getEvents(block, manifest), /does not match requested/);
  h.wrong(false);
  h.removed(true);
  await assert.rejects(h.adapter.getEvents(block, manifest), /removed log/);
  h.removed(false);
  h.setHash(H2);
  await assert.rejects(h.adapter.getEvents(block, manifest), /changed during log retrieval/);
});
test("RPC adapter fails closed without a configured ABI decoder or mark tick reader", async () => {
  const h = fixture();
  assert.throws(() => createCanonicalRpcAdapter(h.transport, {}), /decoder/);
  const adapter = createCanonicalRpcAdapter(h.transport, { decode: () => undefined });
  await assert.rejects(adapter.getMarkTicks(manifest), /not configured/);
});

test("portfolio health callback is exposed and receives accounts and manifest", async () => {
  const h = fixture();
  const calls = [];
  const adapter = createCanonicalRpcAdapter(h.transport, {
    decode: () => undefined,
    portfolioHealth: async (accounts, deployment) => {
      calls.push({ accounts, deployment });
      return { [addr]: { equity: 100n, requirement: 40n } };
    },
  });
  const health = await adapter.getPortfolioHealth([addr], manifest);
  assert.equal(health[addr].equity, 100n);
  assert.equal(health[addr].requirement, 40n);
  assert.deepEqual(calls[0].accounts, [addr]);
  assert.equal(calls[0].deployment, manifest);
  const without = createCanonicalRpcAdapter(h.transport, { decode: () => undefined });
  assert.equal(without.getPortfolioHealth, undefined);
});

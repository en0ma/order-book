import test from "node:test";
import assert from "node:assert/strict";
import { assembleRecoveryBundle, validateRecoveryBundle, executeReadyTasks } from "../dist/recovery.js";
import { operatorManifestIdentity } from "../dist/index.js";
const addr = "0x1111111111111111111111111111111111111111";
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 0,
  collateral: { token: addr, decimals: 18 },
  markets: [{ id: "ETH", core: addr, advanced: addr, oracle: addr }] };
const identity = operatorManifestIdentity(manifest);
const head = { number: 12, hash: "0xabc", parentHash: "0xdef" };
const checkpoint = { version: 1, chainId: 1, deploymentBlock: 0, manifestIdentity: identity,
  branchEpoch: 2, head, state: { pools: [], conditionals: [], trailing: [], managedQuotes: [],
    portfolioLocks: [], knownMakerKeys: [], activeConditionalIds: [], activeTrailingIds: [] } };
const strategyHead = { number: 12, hash: "0xabc" };
const strategies = { version: 1, records: [] };
const snapshot = { version: 1, chainId: 1, head: { number: 12, hash: "0xabc" },
  pools: [], conditionals: [], trailing: [], managedQuotes: [], portfolioLocks: [] };
const diagnostics = { status: "healthy", headBlock: 12, remoteHead: 12, safeHead: 12, lagBlocks: 0,
  appliedBlocks: 0, taskCounts: {}, activeConditionals: 0, activeTrailing: 0,
  managedQuotes: 0, portfolioAccounts: 0 };
test("strategy and index state must use the same canonical head and manifest", () => {
  const bundle = assembleRecoveryBundle(manifest, checkpoint, strategies, strategyHead);
  assert.doesNotThrow(() => validateRecoveryBundle(manifest, bundle));
  assert.throws(() => assembleRecoveryBundle(manifest, checkpoint, strategies,
    { number: 12, hash: "0xorphan" }), /heads/);
  assert.throws(() => validateRecoveryBundle(manifest, { ...bundle, identity: "wrong" }), /identity/);
  assert.throws(() => validateRecoveryBundle(manifest, { ...bundle,
    strategies: { version: 1, records: [{ strategyId: "not-decimal" }] } }), /strategyId/);
  assert.throws(() => validateRecoveryBundle(manifest, { ...bundle,
    checkpoint: { ...checkpoint, state: { ...checkpoint.state, pools: null } } }), /map|iterable|read/i);
});
test("keeper task admission checks canonical readiness and idempotent simulation", async () => {
  const operations = [];
  const executor = {
    alreadySubmitted: async () => false,
    simulate: async () => true,
    submit: async (_task, key) => { operations.push(key); return "0xtx"; },
  };
  const tasks = [{ kind: "checkTrailing", marketId: "ETH", orderId: 1n }];
  const verifier = { getCanonicalBlockHash: async () => head.hash };
  const result = await executeReadyTasks(manifest, checkpoint, snapshot, diagnostics, tasks, executor, verifier);
  assert.equal(result.admitted, 1);
  assert.equal(result.transactionIds[0], "0xtx");
  assert.ok(operations[0].includes("branch:2"));
  await assert.rejects(() => executeReadyTasks(manifest, checkpoint, snapshot,
    { ...diagnostics, status: "stalled" }, tasks, executor), /not ready/);
  await assert.rejects(() => executeReadyTasks(manifest, checkpoint,
    { ...snapshot, head: { number: 12, hash: "0xorphan" } }, diagnostics, tasks, executor), /not ready/);
  assert.equal(operations.length, 1);
  await assert.rejects(() => executeReadyTasks(manifest, checkpoint, snapshot, diagnostics,
    tasks, executor, { getCanonicalBlockHash: async () => "0xorphan" }), /canonical head hash/);
  assert.equal(operations.length, 1);
});

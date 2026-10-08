import test from "node:test";
import assert from "node:assert/strict";
import { StrategyRegistry, planStrategyTasks } from "../dist/strategies.js";
import { normalizeCanonicalEvent } from "../dist/integration.js";
import { operatorManifestIdentity } from "../dist/index.js";
const owner = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const strategy = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const core = "0x1111111111111111111111111111111111111111";
const advanced = "0x2222222222222222222222222222222222222222";
const oracle = "0x3333333333333333333333333333333333333333";
const token = "0x4444444444444444444444444444444444444444";
const manifest = {
  schemaVersion: 1, chainId: 1, deploymentBlock: 0,
  collateral: { token, decimals: 18 },
  markets: [{ id: "ETH", core, advanced, executionStrategy: strategy, oracle }],
};
const envelope = (event: any, blockNumber = 1) => ({
  chainId: 1, blockNumber, blockHash: "0x" + "ff".repeat(32),
  transactionIndex: 0, logIndex: 0, address: strategy, event,
});
const normalize = (event: any) => normalizeCanonicalEvent(manifest, envelope(event));
const key = (id: bigint) => JSON.stringify(["ETH", id.toString()]);

test("strategy events are authenticated by the configured module", () => {
  const placed = { name: "IcebergPlaced", strategyId: 1n, owner, side: 0, tick: 42, totalLots: 10n, displayLots: 2n };
  assert.equal(normalize(placed).marketId, "ETH");
  assert.throws(() => normalizeCanonicalEvent(manifest, { ...envelope(placed), address: advanced }), /unexpected address/);
  assert.notEqual(operatorManifestIdentity(manifest), operatorManifestIdentity({
    ...manifest, markets: [{ ...manifest.markets[0], executionStrategy: undefined }],
  }));
});
test("placement, completion, deterministic snapshot and recovery", () => {
  const r = new StrategyRegistry();
  r.apply(normalize({ name: "IcebergPlaced", strategyId: 1n, owner, side: 0, tick: 42, totalLots: 10n, displayLots: 2n }));
  r.apply(normalize({ name: "TWAPPlaced", strategyId: 2n, owner, side: 1, limitTick: 40, totalLots: 15n, sliceLots: 3n, startTime: 100n, interval: 10n, deadline: 200n }));
  r.apply(normalize({ name: "PeggedPlaced", strategyId: 3n, owner, side: 0, offsetTicks: -1, priceBoundTick: 70, lots: 6n, initialTick: 49 }));
  const snapshot = JSON.parse(JSON.stringify(r.snapshot()));
  const restored = new StrategyRegistry();
  restored.restore(snapshot);
  assert.deepEqual(restored.snapshot(), snapshot);
  const observed = new Map([
    [key(1n), { active: true, remainingLots: 8n, visibleLots: 0n, nextExecution: 0n, currentTick: 42 }],
    [key(2n), { active: true, remainingLots: 12n, visibleLots: 0n, nextExecution: 110n, currentTick: 40 }],
    [key(3n), { active: true, remainingLots: 6n, visibleLots: 6n, nextExecution: 0n, currentTick: 49 }],
  ]);
  assert.deepEqual(planStrategyTasks(restored, observed, 110n, { ETH: 55 }).map(t => t.kind),
    ["refreshIceberg", "executeTWAPSlice", "syncPegged"]);
  assert.equal(planStrategyTasks(restored, new Map(), 110n, { ETH: 55 }).length, 0);
  restored.apply(normalize({ name: "StrategyCompleted", strategyId: 2n }));
  assert.equal(restored.records.size, 2);
  restored.apply(normalize({ name: "StrategyCancelled", strategyId: 1n, remainingLots: 8n }));
  assert.equal(restored.records.size, 1);
});
test("failed batch and invalid recovery are atomic", () => {
  const r = new StrategyRegistry();
  const placed = normalize({ name: "IcebergPlaced", strategyId: 1n, owner, side: 0, tick: 42, totalLots: 10n, displayLots: 2n });
  assert.throws(() => r.applyBatch([placed, placed]), /duplicate/);
  assert.equal(r.records.size, 0);
  r.apply(placed);
  const old = r.snapshot();
  assert.throws(() => r.restore({ version: 1, records: [{ ...old.records[0], key: "forged" }] }), /key/);
  assert.deepEqual(r.snapshot(), old);
});

test("pegged keeper settles exhausted quotes at unchanged marks and respects bounds", () => {
  const r = new StrategyRegistry();
  const bid = { name: "PeggedPlaced", strategyId: 10n, owner, side: 0, offsetTicks: 5, priceBoundTick: 50, lots: 10n, initialTick: 50 };
  const ask = { name: "PeggedPlaced", strategyId: 11n, owner, side: 1, offsetTicks: -5, priceBoundTick: 50, lots: 10n, initialTick: 50 };
  r.apply(normalize(bid));
  r.apply(normalize(ask));
  const observations = new Map([
    [key(10n), { active: true, remainingLots: 10n, visibleLots: 10n, nextExecution: 0n, currentTick: 50 }],
    [key(11n), { active: true, remainingLots: 10n, visibleLots: 10n, nextExecution: 0n, currentTick: 50 }],
  ]);
  assert.equal(planStrategyTasks(r, observations, 0n, { ETH: 50 }).length, 0);
  observations.set(key(10n), { active: true, remainingLots: 10n, visibleLots: 0n, nextExecution: 0n, currentTick: 50 });
  assert.deepEqual(planStrategyTasks(r, observations, 0n, { ETH: 50 }).map(t => t.strategyId), [10n]);
  assert.equal(planStrategyTasks(r, observations, 0n, { ETH: 55 }).length, 1);
  observations.set(key(10n), { active: true, remainingLots: 10n, visibleLots: 10n, nextExecution: 0n, currentTick: 50 });
  assert.equal(planStrategyTasks(r, observations, 0n, { ETH: 55 }).length, 0);
});

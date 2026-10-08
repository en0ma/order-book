import { readFileSync } from "node:fs";
import test from "node:test";
import assert from "node:assert/strict";

import {
  ManifestError,
  OrderBookSDK,
  encodePackedQuoteUpdates,
  executeDeploymentVerification,
  validateManifest,
  verifyDeploymentResults,
  type DeploymentManifest,
} from "../dist/index.js";

const A = "0x1111111111111111111111111111111111111111";
const B = "0x2222222222222222222222222222222222222222";
const C = "0x3333333333333333333333333333333333333333";
const D = "0x4444444444444444444444444444444444444444";
const E = "0x5555555555555555555555555555555555555555";
const F = "0x6666666666666666666666666666666666666666";
const G = "0x7777777777777777777777777777777777777777";
const H = "0x8888888888888888888888888888888888888888";

function standaloneManifest(): DeploymentManifest {
  return {
    schemaVersion: 1,
    chainId: 1,
    deploymentBlock: 123,
    packageVersion: "0.1.0",
    protocolAdmin: H,
    collateral: { token: A, decimals: 6 },
    markets: [
      {
        id: "ETH-PERP",
        core: B,
        advanced: C,
        marketMaker: D,
        integrationLens: E,
        oracle: F,
        fundingUpdater: G,
        scales: { collateralUnitsPerLotTick: "1000" },
        parameters: {
          executionBandTicks: 40,
          initialMarginBps: 1000,
          takerFeeBps: 5,
          makerRebateBps: 2,
          oracleMaxAgeSeconds: 60,
        },
      },
    ],
  };
}

test("validates a standalone manifest", () => {
  assert.equal(validateManifest(standaloneManifest()).markets[0].id, "ETH-PERP");
});

test("routes standalone take and maker add to core", () => {
  const sdk = new OrderBookSDK(standaloneManifest());

  assert.deepEqual(sdk.take("ETH-PERP", 0, 100, 5n, 0), {
    target: B,
    functionName: "take",
    args: [0, 100, 5n, 0],
  });

  assert.deepEqual(sdk.addLiquidity("ETH-PERP", 1, 105, 9n), {
    target: B,
    functionName: "addLiquidity",
    args: [1, 105, 9n],
  });
});

test("validates the repository example manifest", () => {
  const raw = readFileSync(new URL("../../deployments/example.json", import.meta.url), "utf8");
  const manifest = JSON.parse(raw) as DeploymentManifest;
  assert.equal(validateManifest(manifest).markets[0].id, "ETH-PERP");
});

test("plans iceberg, TWAP, and pegged strategy actions", () => {
  const manifest = standaloneManifest();
  manifest.markets[0].executionStrategy = H;
  const sdk = new OrderBookSDK(manifest);

  assert.deepEqual(sdk.placeIceberg("ETH-PERP", 0, 99, 100n, 10n), {
    target: H,
    functionName: "placeIceberg",
    args: [0, 99, 100n, 10n],
  });
  assert.deepEqual(
    sdk.placeTWAP("ETH-PERP", 0, 105, 100n, 10n, 1_000n, 60n, 2_000n),
    {
      target: H,
      functionName: "placeTWAP",
      args: [0, 105, 100n, 10n, 1_000n, 60n, 2_000n],
    },
  );
  assert.deepEqual(sdk.placePegged("ETH-PERP", 1, 2, 95, 25n), {
    target: H,
    functionName: "placePegged",
    args: [1, 2, 95, 25n],
  });
  assert.deepEqual(sdk.refreshIceberg("ETH-PERP", 7n), {
    target: H,
    functionName: "refreshIceberg",
    args: [7n],
  });
  assert.deepEqual(sdk.executeTWAPSlice("ETH-PERP", 8n), {
    target: H,
    functionName: "executeTWAPSlice",
    args: [8n],
  });
  assert.deepEqual(sdk.syncPegged("ETH-PERP", 9n), {
    target: H,
    functionName: "syncPegged",
    args: [9n],
  });
});

test("routes portfolio risk growth through coordinator", () => {
  const manifest = standaloneManifest();
  manifest.portfolio = { coordinator: G, policy: H, vault: A };
  manifest.markets[0].portfolioMarketIndex = 3;
  manifest.markets[0].parameters.riskGroup = 1;
  manifest.markets[0].parameters.portfolioMarginBps = 1000;
  manifest.markets[0].parameters.hedgeCreditBps = 5000;

  const sdk = new OrderBookSDK(manifest);

  assert.deepEqual(sdk.take("ETH-PERP", 1, 95, 7n, 1), {
    target: G,
    functionName: "take",
    args: [3n, 1, 95, 7n, 1],
  });

  assert.deepEqual(sdk.addLiquidity("ETH-PERP", 0, 90, 11n), {
    target: G,
    functionName: "addLiquidity",
    args: [3n, 0, 90, 11n],
  });
});

test("routes collateral and liquidity lifecycle by deployment mode", () => {
  const standalone = new OrderBookSDK(standaloneManifest());
  assert.deepEqual(standalone.deposit("ETH-PERP", 100n), {
    target: B,
    functionName: "depositCollateral",
    args: [100n],
  });
  assert.deepEqual(standalone.withdraw("ETH-PERP", 50n), {
    target: B,
    functionName: "withdrawCollateral",
    args: [50n],
  });
  assert.deepEqual(standalone.removeLiquidity("ETH-PERP", 1, 105, 9, 3n), {
    target: B,
    functionName: "removeShares",
    args: [1, 105, 3n],
  });

  const manifest = standaloneManifest();
  manifest.portfolio = { coordinator: G, policy: H, vault: A };
  manifest.markets[0].portfolioMarketIndex = 2;
  manifest.markets[0].parameters.riskGroup = 1;
  manifest.markets[0].parameters.portfolioMarginBps = 1000;
  manifest.markets[0].parameters.hedgeCreditBps = 5000;
  const portfolio = new OrderBookSDK(manifest);

  assert.deepEqual(portfolio.deposit("ETH-PERP", 100n), {
    target: A,
    functionName: "deposit",
    args: [100n],
  });
  assert.deepEqual(portfolio.withdraw("ETH-PERP", 50n), {
    target: G,
    functionName: "withdraw",
    args: [50n],
  });
  assert.deepEqual(portfolio.removeLiquidity("ETH-PERP", 0, 90, 4, 7n), {
    target: G,
    functionName: "removeLiquidity",
    args: [2n, 0, 90, 4, 7n],
  });
});

test("advanced orders always target the advanced gateway", () => {
  const manifest = standaloneManifest();
  manifest.portfolio = { coordinator: G, policy: H, vault: A };
  manifest.markets[0].portfolioMarketIndex = 0;
  manifest.markets[0].parameters.riskGroup = 1;
  manifest.markets[0].parameters.portfolioMarginBps = 1000;
  manifest.markets[0].parameters.hedgeCreditBps = 5000;
  const sdk = new OrderBookSDK(manifest);

  assert.deepEqual(
    sdk.placeConditional("ETH-PERP", 0, true, 101, 100, 12n, 0, true),
    {
      target: C,
      functionName: "placeConditionalOrder",
      args: [0, true, 101, 100, 12n, 0, true],
    },
  );
});

test("plans reduce-only, trailing, and order graph actions", () => {
  const sdk = new OrderBookSDK(standaloneManifest());

  assert.deepEqual(sdk.takeReduceOnly("ETH-PERP", 1, 95, 6n, 0), {
    target: C,
    functionName: "takeReduceOnly",
    args: [1, 95, 6n, 0],
  });
  assert.deepEqual(sdk.takeMinFill("ETH-PERP", 0, 105, 10n, 7n, true), {
    target: C,
    functionName: "takeMinFill",
    args: [0, 105, 10n, 7n, true],
  });
  assert.deepEqual(sdk.placeTrailing("ETH-PERP", 1, 8, 95, 4n, 0, true), {
    target: C,
    functionName: "placeTrailingOrder",
    args: [1, 8, 95, 4n, 0, true],
  });
  assert.deepEqual(sdk.linkOCO("ETH-PERP", 1n, 2n), {
    target: C,
    functionName: "linkOCO",
    args: [1n, 2n],
  });
  assert.deepEqual(sdk.linkOTO("ETH-PERP", 1n, 3n), {
    target: C,
    functionName: "linkOTO",
    args: [1n, 3n],
  });
});

test("encodes packed MM records exactly as the Solidity layout", () => {
  const packed = encodePackedQuoteUpdates([
    { side: 0, tick: 90, lots: 12n },
    { side: 1, tick: 110, lots: 25n },
  ]);

  assert.equal(packed.length, 2 + 64);

  const first = BigInt("0x" + packed.slice(2, 34));
  const second = BigInt("0x" + packed.slice(34, 66));

  assert.equal(first & ((1n << 96n) - 1n), 12n);
  assert.equal((first >> 96n) & 0xffffn, 90n);
  assert.equal((first >> 112n) & 1n, 0n);

  assert.equal(second & ((1n << 96n) - 1n), 25n);
  assert.equal((second >> 96n) & 0xffffn, 110n);
  assert.equal((second >> 112n) & 1n, 1n);
});

test("rejects unsorted packed MM updates", () => {
  assert.throws(
    () =>
      encodePackedQuoteUpdates([
        { side: 1, tick: 110, lots: 1n },
        { side: 0, tick: 90, lots: 1n },
      ]),
    /strictly sorted/,
  );
});

test("rejects malformed or inconsistent manifests", () => {
  const manifest = standaloneManifest();
  manifest.markets[0].portfolioMarketIndex = 0;
  manifest.markets[0].parameters.riskGroup = 1;
  manifest.markets[0].parameters.portfolioMarginBps = 1000;
  manifest.markets[0].parameters.hedgeCreditBps = 5000;
  assert.throws(() => new OrderBookSDK(manifest), ManifestError);

  const duplicate = standaloneManifest();
  duplicate.markets.push({ ...duplicate.markets[0] });
  assert.throws(() => validateManifest(duplicate), /unique/);

  const numericScale = standaloneManifest();
  (numericScale.markets[0].scales as { collateralUnitsPerLotTick: unknown })
    .collateralUnitsPerLotTick = 1000;
  assert.throws(
    () => validateManifest(numericScale),
    /collateralUnitsPerLotTick must be a uint string/,
  );

  const invalidFees = standaloneManifest();
  invalidFees.markets[0].parameters.takerFeeBps = 2;
  invalidFees.markets[0].parameters.makerRebateBps = 3;
  assert.throws(
    () => validateManifest(invalidFees),
    /makerRebateBps cannot exceed takerFeeBps/,
  );
});

test("plans packed quote refresh against configured MM module", () => {
  const sdk = new OrderBookSDK(standaloneManifest());
  const plan = sdk.replaceQuotesPacked("ETH-PERP", [
    { side: 0, tick: 90, lots: 4n },
    { side: 1, tick: 110, lots: 6n },
  ]);

  assert.equal(plan.target, D);
  assert.equal(plan.functionName, "batchReplaceQuotesPacked");
  assert.match(plan.args[0] as string, /^0x[0-9a-f]{64}$/);
});


test("builds standalone deployment verification plans from the manifest", () => {
  const sdk = new OrderBookSDK(standaloneManifest());
  const plans = sdk.deploymentVerificationPlan();

  const byId = new Map(plans.map((plan) => [plan.id, plan]));
  assert.equal(byId.get("market:ETH-PERP:core.owner")?.expected, H);
  assert.equal(byId.get("market:ETH-PERP:core.fundingUpdater")?.expected, G);
  assert.equal(byId.get("market:ETH-PERP:advanced.owner")?.expected, H);
  assert.deepEqual(byId.get("market:ETH-PERP:core.markOracle"), {
    id: "market:ETH-PERP:core.markOracle",
    target: B,
    functionName: "markOracle",
    args: [],
    expected: F,
  });
  assert.deepEqual(byId.get("market:ETH-PERP:core.accountingScale"), {
    id: "market:ETH-PERP:core.accountingScale",
    target: B,
    functionName: "notionalValue",
    args: [1n, 1],
    expected: 1000n,
  });
  assert.equal(byId.get("market:ETH-PERP:advanced.core")?.expected, B);
  assert.deepEqual(byId.get("market:ETH-PERP:advanced.marketMakerModule")?.expected, D);
  assert.equal(byId.has("portfolio:vault.controller"), false);
});

test("builds shared portfolio verification plans and market indexes", () => {
  const manifest = standaloneManifest();
  manifest.portfolio = { coordinator: G, policy: H, vault: A };
  manifest.markets[0].portfolioMarketIndex = 3;
  manifest.markets[0].parameters.riskGroup = 1;
  manifest.markets[0].parameters.portfolioMarginBps = 1000;
  manifest.markets[0].parameters.hedgeCreditBps = 5000;
  manifest.markets[0].portfolioLiquidation = E;
  manifest.markets[0].liquidation = undefined;

  const plans = new OrderBookSDK(manifest).deploymentVerificationPlan();
  const byId = new Map(plans.map((plan) => [plan.id, plan]));

  assert.equal(byId.get("market:ETH-PERP:core.portfolioController")?.expected, G);
  assert.equal(byId.get("market:ETH-PERP:advanced.portfolioController")?.expected, G);
  assert.equal(byId.get("market:ETH-PERP:advanced.portfolioMarketIndex")?.expected, 3n);
  assert.deepEqual(byId.get("market:ETH-PERP:coordinator.marketSlot"), {
    id: "market:ETH-PERP:coordinator.marketSlot",
    target: G,
    functionName: "markets",
    args: [3n],
    expected: [B, C],
  });
  assert.deepEqual(byId.get("market:ETH-PERP:policy.marketSlot"), {
    id: "market:ETH-PERP:policy.marketSlot",
    target: H,
    functionName: "markets",
    args: [3n],
    expected: [B, 1n, 1000n, 5000n],
  });
  assert.equal(byId.get("market:ETH-PERP:advanced.liquidationModule")?.expected, E);
  assert.equal(byId.get("portfolio:policy.owner")?.expected, H);
  assert.equal(byId.get("portfolio:vault.owner")?.expected, H);
  assert.equal(byId.get("portfolio:vault.controller")?.expected, G);
  assert.equal(byId.get("portfolio:policy.sharedCollateralVault")?.expected, A);
  assert.equal(byId.get("portfolio:coordinator.policy")?.expected, H);
});

test("verifies read results with address and integer normalization", () => {
  const sdk = new OrderBookSDK(standaloneManifest());
  const plans = sdk.deploymentVerificationPlan().slice(0, 3);
  const results = Object.fromEntries(
    plans.map((plan) => [
      plan.id,
      typeof plan.expected === "string"
        ? plan.expected.toUpperCase().replace("0X", "0x")
        : typeof plan.expected === "bigint"
          ? plan.expected.toString()
          : plan.expected,
    ]),
  );

  assert.deepEqual(verifyDeploymentResults(plans, results), {
    ok: true,
    mismatches: [],
  });

  results[plans[0].id] = A;
  const mismatch = verifyDeploymentResults(plans, results);
  assert.equal(mismatch.ok, false);
  assert.equal(mismatch.mismatches[0].id, plans[0].id);
});

test("reports missing deployment verification reads", () => {
  const sdk = new OrderBookSDK(standaloneManifest());
  const plan = sdk.deploymentVerificationPlan()[0];
  const result = verifyDeploymentResults([plan], {});
  assert.equal(result.ok, false);
  assert.equal(result.mismatches[0].actual, undefined);
});


test("verifies standalone liquidation back-references and maintenance margin", () => {
  const manifest = standaloneManifest();
  manifest.markets[0].liquidation = G;
  manifest.markets[0].parameters.maintenanceMarginBps = 500;

  const byId = new Map(
    new OrderBookSDK(manifest).deploymentVerificationPlan().map((plan) => [plan.id, plan]),
  );

  assert.equal(byId.get("market:ETH-PERP:liquidation.core")?.expected, B);
  assert.equal(byId.get("market:ETH-PERP:liquidation.gateway")?.expected, C);
  assert.equal(
    byId.get("market:ETH-PERP:liquidation.maintenanceMarginBps")?.expected,
    500n,
  );
});

test("does not call standalone liquidation getters for portfolio modules", () => {
  const manifest = standaloneManifest();
  manifest.portfolio = { coordinator: G, policy: H, vault: A };
  manifest.markets[0].portfolioMarketIndex = 0;
  manifest.markets[0].parameters.riskGroup = 1;
  manifest.markets[0].parameters.portfolioMarginBps = 1000;
  manifest.markets[0].parameters.hedgeCreditBps = 5000;
  manifest.markets[0].liquidation = E;
  manifest.markets[0].parameters.maintenanceMarginBps = 500;

  const ids = new Set(
    new OrderBookSDK(manifest).deploymentVerificationPlan().map((plan) => plan.id),
  );

  assert.equal(ids.has("market:ETH-PERP:liquidation.core"), false);
  assert.equal(ids.has("market:ETH-PERP:liquidation.gateway"), false);
  assert.equal(ids.has("market:ETH-PERP:liquidation.maintenanceMarginBps"), false);
});

test("verifies coordinator tuple results positionally", () => {
  const manifest = standaloneManifest();
  manifest.portfolio = { coordinator: G, policy: H, vault: A };
  manifest.markets[0].portfolioMarketIndex = 0;
  manifest.markets[0].parameters.riskGroup = 1;
  manifest.markets[0].parameters.portfolioMarginBps = 1000;
  manifest.markets[0].parameters.hedgeCreditBps = 5000;
  const sdk = new OrderBookSDK(manifest);
  const plan = sdk
    .deploymentVerificationPlan()
    .find((item) => item.id === "market:ETH-PERP:coordinator.marketSlot");
  assert.ok(plan);

  assert.equal(
    verifyDeploymentResults([plan], {
      [plan.id]: [B.toUpperCase().replace("0X", "0x"), C],
    }).ok,
    true,
  );
  assert.equal(
    verifyDeploymentResults([plan], {
      [plan.id]: [C, B],
    }).ok,
    false,
  );
});


test("executes live deployment verification fail-closed", async () => {
  const manifest = standaloneManifest();
  manifest.markets[0].liquidation = G;
  manifest.markets[0].parameters.maintenanceMarginBps = 500;

  const sdk = new OrderBookSDK(manifest);
  const expected = new Map(
    sdk.deploymentVerificationPlan().map((plan) => [plan.id, plan.expected]),
  );

  const result = await executeDeploymentVerification(manifest, {
    async chainId() {
      return 1;
    },
    async getCode() {
      return "0x6000";
    },
    async read(plan) {
      return expected.get(plan.id);
    },
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.readErrors, []);
  assert.deepEqual(result.missingCode, []);
  assert.equal(result.chainIdMismatch, undefined);
});

test("live verifier reports wrong chain, missing code, read errors and mismatches", async () => {
  const manifest = standaloneManifest();
  const sdk = new OrderBookSDK(manifest);
  const plans = sdk.deploymentVerificationPlan();
  const first = plans[0];

  const result = await executeDeploymentVerification(manifest, {
    async chainId() {
      return 10;
    },
    async getCode(address) {
      return address.toLowerCase() === manifest.markets[0].core.toLowerCase()
        ? "0x"
        : "0x6000";
    },
    async read(plan) {
      if (plan.id === first.id) throw new Error("rpc unavailable");
      if (plan.id === "market:ETH-PERP:core.fundingUpdater") return A;
      return plan.expected;
    },
  });

  assert.equal(result.ok, false);
  assert.deepEqual(result.chainIdMismatch, { expected: 1, actual: 10 });
  assert.ok(result.missingCode.some((entry) => entry.address === manifest.markets[0].core));
  assert.ok(result.readErrors.some((entry) => entry.id === first.id));
  assert.ok(
    result.mismatches.some(
      (entry) => entry.id === "market:ETH-PERP:core.fundingUpdater",
    ),
  );
});


test("live verifier includes collateral bytecode in preflight", async () => {
  const manifest = standaloneManifest();
  const sdk = new OrderBookSDK(manifest);
  const expected = new Map(
    sdk.deploymentVerificationPlan().map((plan) => [plan.id, plan.expected]),
  );

  const result = await executeDeploymentVerification(manifest, {
    async chainId() {
      return manifest.chainId;
    },
    async getCode(address) {
      return address.toLowerCase() === manifest.collateral.token.toLowerCase()
        ? "0x"
        : "0x6000";
    },
    async read(plan) {
      return expected.get(plan.id);
    },
  });

  assert.equal(result.ok, false);
  assert.ok(
    result.missingCode.some((entry) => entry.id === "collateral.token"),
  );
});

test("live verifier captures chain and bytecode RPC failures", async () => {
  const manifest = standaloneManifest();
  const sdk = new OrderBookSDK(manifest);
  const expected = new Map(
    sdk.deploymentVerificationPlan().map((plan) => [plan.id, plan.expected]),
  );

  const result = await executeDeploymentVerification(manifest, {
    async chainId() {
      throw new Error("chain rpc unavailable");
    },
    async getCode(address) {
      if (address.toLowerCase() === manifest.collateral.token.toLowerCase()) {
        throw new Error("code rpc unavailable");
      }
      return "0x6000";
    },
    async read(plan) {
      return expected.get(plan.id);
    },
  });

  assert.equal(result.ok, false);
  assert.ok(
    result.readErrors.some(
      (entry) =>
        entry.id === "preflight.chainId"
          && entry.error === "chain rpc unavailable",
    ),
  );
  assert.ok(
    result.readErrors.some(
      (entry) =>
        entry.id === "preflight.code:collateral.token"
          && entry.error === "code rpc unavailable",
    ),
  );
});

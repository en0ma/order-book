import test from "node:test";
import assert from "node:assert/strict";

import {
  DeploymentVerificationError,
  assertDeploymentVerified,
  verifyDeploymentOrThrow,
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

const manifest: DeploymentManifest = {
  schemaVersion: 1,
  chainId: 1,
  deploymentBlock: 100,
  packageVersion: "0.1.0",
  protocolAdmin: H,
  collateral: { token: A, decimals: 6 },
  markets: [{
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
    },
  }],
};

test("assertDeploymentVerified fails closed with the full report", () => {
  const result = {
    ok: false,
    mismatches: [{ id: "x", expected: 1n, actual: 2n }],
    readErrors: [],
    missingCode: [],
  };
  assert.throws(
    () => assertDeploymentVerified(result),
    (error: unknown) =>
      error instanceof DeploymentVerificationError
      && error.result === result
      && /1 issue/.test(error.message),
  );
});

test("verifyDeploymentOrThrow returns only fully verified deployments", async () => {
  const result = await verifyDeploymentOrThrow(manifest, {
    async chainId() { return manifest.chainId; },
    async getCode() { return "0x6000"; },
    async read(plan) { return plan.expected; },
  });
  assert.equal(result.ok, true);

  await assert.rejects(
    () => verifyDeploymentOrThrow(manifest, {
      async chainId() { return 10; },
      async getCode() { return "0x6000"; },
      async read(plan) { return plan.expected; },
    }),
    DeploymentVerificationError,
  );
});


test("verifyDeploymentOrThrow requires chain and bytecode preflights", async () => {
  await assert.rejects(
    () => verifyDeploymentOrThrow(manifest, {
      async read(plan) { return plan.expected; },
    }),
    (error: unknown) =>
      error instanceof DeploymentVerificationError
      && error.result.readErrors.some((entry) => entry.id === "preflight.chainId")
      && error.result.readErrors.some((entry) => entry.id === "preflight.getCode"),
  );

  await assert.rejects(
    () => verifyDeploymentOrThrow(manifest, {
      async chainId() { return manifest.chainId; },
      async read(plan) { return plan.expected; },
    }),
    (error: unknown) =>
      error instanceof DeploymentVerificationError
      && error.result.readErrors.some((entry) => entry.id === "preflight.getCode"),
  );
});

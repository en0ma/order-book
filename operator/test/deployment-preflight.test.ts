import test from "node:test";
import assert from "node:assert/strict";
import { verifyPortfolioDeployment } from "../dist/deployment-preflight.js";

const address = n => "0x" + n.repeat(40);
const core0 = address("1"), core1 = address("2"), gateway0 = address("3");
const gateway1 = address("4"), coordinator = address("5"), policy = address("6");
const vault = address("7"), oracle = address("8"), token = address("9");
const manifest = {
  schemaVersion: 1, chainId: 1, deploymentBlock: 10,
  collateral: { token, decimals: 18 },
  portfolio: { coordinator, policy, vault },
  markets: [
    { id: "SECOND", core: core1, advanced: gateway1, oracle, portfolioMarketIndex: 1 },
    { id: "FIRST", core: core0, advanced: gateway0, oracle, portfolioMarketIndex: 0 },
  ],
};
const reader = () => ({
  chainId: async () => 1,
  coordinatorMarketCount: async () => 2,
  policyMarketCount: async () => 2,
  coordinatorMarket: async (_, i) => i === 0 ? { core: core0, gateway: gateway0 } : { core: core1, gateway: gateway1 },
  policyMarketCore: async (_, i) => i === 0 ? core0 : core1,
  coordinatorPolicy: async () => policy,
  coordinatorVault: async () => vault,
  policySharedCollateralVault: async () => vault,
  vaultController: async () => coordinator,
  vaultCollateralToken: async () => token,
  corePortfolioController: async () => coordinator,
  coreAdvancedModule: async core => core === core0 ? gateway0 : gateway1,
  gatewayCore: async gateway => gateway === gateway0 ? core0 : core1,
  gatewayPortfolioController: async () => coordinator,
  gatewayPortfolioMarketIndex: async gateway => gateway === gateway0 ? 0 : 1,
});
test("verifies out-of-order manifest against actual on-chain portfolio tuple", async () => {
  await assert.doesNotReject(verifyPortfolioDeployment(manifest, reader()));
});
test("rejects wrong chain, counts, vault and core/gateway tuple", async () => {
  await assert.rejects(verifyPortfolioDeployment(manifest, {
    ...reader(), chainId: async () => 2,
  }), /chain mismatch/);
  await assert.rejects(verifyPortfolioDeployment(manifest, {
    ...reader(), coordinatorMarketCount: async () => 1,
  }), /market count mismatch/);
  await assert.rejects(verifyPortfolioDeployment(manifest, {
    ...reader(), policySharedCollateralVault: async () => token,
  }), /policy or vault mismatch/);
  await assert.rejects(verifyPortfolioDeployment(manifest, {
    ...reader(), vaultController: async () => core0,
  }), /policy or vault mismatch/);
  await assert.rejects(verifyPortfolioDeployment(manifest, {
    ...reader(), coordinatorMarket: async () => ({ core: core0, gateway: gateway0 }),
  }), /tuple mismatch at index 1/);
  await assert.rejects(verifyPortfolioDeployment(manifest, {
    ...reader(), policyMarketCore: async () => core0,
  }), /tuple mismatch at index 1/);
});

test("rejects miswired market modules, index, controller and collateral asset", async () => {
  await assert.rejects(verifyPortfolioDeployment(manifest, {
    ...reader(), vaultCollateralToken: async () => oracle,
  }), /policy or vault mismatch/);
  for (const override of [
    { corePortfolioController: async () => core0 },
    { coreAdvancedModule: async () => gateway0 },
    { gatewayCore: async () => core0 },
    { gatewayPortfolioController: async () => core1 },
    { gatewayPortfolioMarketIndex: async () => 0 },
  ]) {
    await assert.rejects(verifyPortfolioDeployment(manifest, {
      ...reader(), ...override,
    }), /tuple mismatch/);
  }
});

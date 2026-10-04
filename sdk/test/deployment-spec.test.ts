import test from "node:test";
import assert from "node:assert/strict";

import {
  ManifestError,
  buildDeploymentManifest,
  compileDeploymentEnvironments,
  validateDeploymentSpec,
  type DeploymentSpec,
} from "../dist/index.js";

const ADMIN = "0x1111111111111111111111111111111111111111";
const TOKEN = "0x2222222222222222222222222222222222222222";
const ORACLE_A = "0x3333333333333333333333333333333333333333";
const ORACLE_B = "0x4444444444444444444444444444444444444444";
const FUNDING_A = "0x5555555555555555555555555555555555555555";
const FUNDING_B = "0x6666666666666666666666666666666666666666";
const CORE_A = "0x7777777777777777777777777777777777777777";
const ADV_A = "0x8888888888888888888888888888888888888888";
const MM_A = "0x9999999999999999999999999999999999999999";
const LENS_A = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const CORE_B = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const ADV_B = "0xcccccccccccccccccccccccccccccccccccccccc";
const MM_B = "0xdddddddddddddddddddddddddddddddddddddddd";
const LENS_B = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const COORDINATOR = "0x1234567890123456789012345678901234567890";
const POLICY = "0x2345678901234567890123456789012345678901";
const VAULT = "0x3456789012345678901234567890123456789012";
const PORTFOLIO_LIQ = "0x4567890123456789012345678901234567890123";

function standaloneSpec(): DeploymentSpec {
  return {
    schemaVersion: 1,
    mode: "standalone",
    protocolAdmin: ADMIN,
    collateral: { token: TOKEN, decimals: 6 },
    markets: [{
      id: "ETH-PERP",
      fundingUpdater: FUNDING_A,
      oracle: ORACLE_A,
      executionBandTicks: 40,
      initialMarginBps: 1000,
      maintenanceMarginBps: 500,
      takerFeeBps: 5,
      makerRebateBps: 2,
      liquidatorRewardBps: 25,
      collateralUnitsPerLotTick: "1000",
      oracleMaxAgeSeconds: 60,
    }],
  };
}

function portfolioSpec(): DeploymentSpec {
  return {
    schemaVersion: 1,
    mode: "portfolio",
    protocolAdmin: ADMIN,
    collateral: { token: TOKEN, decimals: 6 },
    markets: [
      {
        id: "ETH-PERP",
        fundingUpdater: FUNDING_A,
        oracle: ORACLE_A,
        executionBandTicks: 40,
        initialMarginBps: 1000,
        takerFeeBps: 5,
        makerRebateBps: 2,
        collateralUnitsPerLotTick: "1000",
        riskGroup: 1,
        portfolioMarginBps: 1000,
        hedgeCreditBps: 5000,
      },
      {
        id: "BTC-PERP",
        fundingUpdater: FUNDING_B,
        oracle: ORACLE_B,
        executionBandTicks: 60,
        initialMarginBps: 1200,
        takerFeeBps: 7,
        makerRebateBps: 3,
        collateralUnitsPerLotTick: "2000",
        riskGroup: 1,
        portfolioMarginBps: 1200,
        hedgeCreditBps: 5000,
      },
    ],
  };
}

test("compiles standalone deployment spec to exact Foundry environment", () => {
  const [deployment] = compileDeploymentEnvironments(standaloneSpec());
  assert.equal(deployment.script, "DeployStandalone");
  assert.equal(deployment.marketId, "ETH-PERP");
  assert.deepEqual(deployment.env, {
    PROTOCOL_ADMIN: ADMIN,
    FUNDING_UPDATER: FUNDING_A,
    COLLATERAL_TOKEN: TOKEN,
    MARK_ORACLE: ORACLE_A,
    EXECUTION_BAND_TICKS: "40",
    INITIAL_MARGIN_BPS: "1000",
    MAINTENANCE_MARGIN_BPS: "500",
    TAKER_FEE_BPS: "5",
    MAKER_REBATE_BPS: "2",
    LIQUIDATOR_REWARD_BPS: "25",
    COLLATERAL_UNITS_PER_LOT_TICK: "1000",
  });
});

test("compiles portfolio arrays in manifest market order", () => {
  const [deployment] = compileDeploymentEnvironments(portfolioSpec());
  assert.equal(deployment.script, "DeployPortfolio");
  assert.equal(deployment.marketId, undefined);
  assert.equal(deployment.env.FUNDING_UPDATERS, `${FUNDING_A},${FUNDING_B}`);
  assert.equal(deployment.env.MARK_ORACLES, `${ORACLE_A},${ORACLE_B}`);
  assert.equal(deployment.env.EXECUTION_BAND_TICKS, "40,60");
  assert.equal(deployment.env.COLLATERAL_UNITS_PER_LOT_TICK, "1000,2000");
  assert.equal(deployment.env.RISK_GROUPS, "1,1");
  assert.equal(deployment.env.HEDGE_CREDIT_BPS, "5000,5000");
});

test("rejects deployment specs the Solidity bootstrap rejects", () => {
  const invalidStandalone = standaloneSpec();
  if (invalidStandalone.mode !== "standalone") throw new Error("bad fixture");
  invalidStandalone.markets[0].maintenanceMarginBps = 1000;
  assert.throws(
    () => validateDeploymentSpec(invalidStandalone),
    /maintenanceMarginBps must be positive and below initialMarginBps/,
  );

  const invalidPortfolio = portfolioSpec();
  if (invalidPortfolio.mode !== "portfolio") throw new Error("bad fixture");
  invalidPortfolio.markets[1].hedgeCreditBps = 4000;
  assert.throws(
    () => validateDeploymentSpec(invalidPortfolio),
    /hedgeCreditBps must match its risk group/,
  );

  const invalidFee = portfolioSpec();
  if (invalidFee.mode !== "portfolio") throw new Error("bad fixture");
  invalidFee.markets[0].makerRebateBps = 6;
  assert.throws(
    () => validateDeploymentSpec(invalidFee),
    /makerRebateBps cannot exceed takerFeeBps/,
  );
});

test("builds standalone manifest from one source deployment spec", () => {
  const manifest = buildDeploymentManifest(
    standaloneSpec(),
    [{
      id: "ETH-PERP",
      core: CORE_A,
      advanced: ADV_A,
      marketMaker: MM_A,
      liquidation: PORTFOLIO_LIQ,
      integrationLens: LENS_A,
    }],
    { chainId: 1, deploymentBlock: 123, packageVersion: "0.2.0" },
  );

  assert.equal(manifest.markets[0].id, "ETH-PERP");
  assert.equal(manifest.markets[0].oracle, ORACLE_A);
  assert.equal(manifest.markets[0].liquidation, PORTFOLIO_LIQ);
  assert.equal(manifest.markets[0].parameters.maintenanceMarginBps, 500);
  assert.equal(manifest.markets[0].portfolioMarketIndex, undefined);
  assert.equal(manifest.portfolio, undefined);
});

test("builds portfolio manifest with deterministic market indexes", () => {
  const manifest = buildDeploymentManifest(
    portfolioSpec(),
    [
      { id: "BTC-PERP", core: CORE_B, advanced: ADV_B, marketMaker: MM_B, integrationLens: LENS_B },
      { id: "ETH-PERP", core: CORE_A, advanced: ADV_A, marketMaker: MM_A, integrationLens: LENS_A },
    ],
    { chainId: 8453, deploymentBlock: 456, packageVersion: "0.2.0" },
    {
      coordinator: COORDINATOR,
      policy: POLICY,
      vault: VAULT,
      liquidation: PORTFOLIO_LIQ,
    },
  );

  assert.deepEqual(manifest.portfolio, {
    coordinator: COORDINATOR,
    policy: POLICY,
    vault: VAULT,
  });
  assert.equal(manifest.markets[0].id, "ETH-PERP");
  assert.equal(manifest.markets[0].core, CORE_A);
  assert.equal(manifest.markets[0].portfolioMarketIndex, 0);
  assert.equal(manifest.markets[0].portfolioLiquidation, PORTFOLIO_LIQ);
  assert.equal(manifest.markets[0].parameters.riskGroup, 1);
  assert.equal(manifest.markets[0].parameters.portfolioMarginBps, 1000);
  assert.equal(manifest.markets[0].parameters.hedgeCreditBps, 5000);
  assert.equal(manifest.markets[1].id, "BTC-PERP");
  assert.equal(manifest.markets[1].core, CORE_B);
  assert.equal(manifest.markets[1].portfolioMarketIndex, 1);
});

test("fails closed when deployed addresses do not match the spec", () => {
  assert.throws(
    () =>
      buildDeploymentManifest(
        portfolioSpec(),
        [{ id: "ETH-PERP", core: CORE_A, advanced: ADV_A }],
        { chainId: 1, deploymentBlock: 1, packageVersion: "0.2.0" },
        {
          coordinator: COORDINATOR,
          policy: POLICY,
          vault: VAULT,
          liquidation: PORTFOLIO_LIQ,
        },
      ),
    ManifestError,
  );
});


test("rejects accounting scales above uint128", () => {
  const spec = standaloneSpec();
  if (spec.mode !== "standalone") throw new Error("bad fixture");
  spec.markets[0].collateralUnitsPerLotTick = (1n << 128n).toString();
  assert.throws(
    () => validateDeploymentSpec(spec),
    /collateralUnitsPerLotTick must fit uint128/,
  );
});

test("requires bootstrap-created module addresses when building manifests", () => {
  const spec = standaloneSpec();
  assert.throws(
    () =>
      buildDeploymentManifest(
        spec,
        [{
          id: "ETH-PERP",
          core: CORE_A,
          advanced: ADV_A,
          marketMaker: "" as never,
          liquidation: PORTFOLIO_LIQ,
          integrationLens: LENS_A,
        }],
        { chainId: 1, deploymentBlock: 1, packageVersion: "0.2.0" },
      ),
    /marketMaker/,
  );

  assert.throws(
    () =>
      buildDeploymentManifest(
        spec,
        [{
          id: "ETH-PERP",
          core: CORE_A,
          advanced: ADV_A,
          marketMaker: MM_A,
          integrationLens: LENS_A,
        }],
        { chainId: 1, deploymentBlock: 1, packageVersion: "0.2.0" },
      ),
    /missing standalone liquidation address/,
  );
});

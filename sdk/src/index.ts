export type Address = `0x${string}`;
export type Hex = `0x${string}`;
export type Side = 0 | 1;
export type FillPolicy = 0 | 1;

export interface DeploymentManifest {
  schemaVersion: 1;
  chainId: number;
  deploymentBlock: number;
  packageVersion: string;
  protocolAdmin: Address;
  collateral: {
    token: Address;
    decimals: number;
  };
  portfolio?: {
    coordinator: Address;
    policy: Address;
    vault: Address;
  };
  markets: MarketManifest[];
}

export interface MarketManifest {
  id: string;
  core: Address;
  advanced: Address;
  marketMaker?: Address;
  liquidation?: Address;
  portfolioLiquidation?: Address;
  integrationLens?: Address;
  oracle: Address;
  fundingUpdater: Address;
  portfolioMarketIndex?: number;
  scales: {
    collateralUnitsPerLotTick: string;
  };
  parameters: {
    executionBandTicks: number;
    initialMarginBps: number;
    maintenanceMarginBps?: number;
    takerFeeBps: number;
    makerRebateBps: number;
    oracleMaxAgeSeconds?: number;
    riskGroup?: number;
    portfolioMarginBps?: number;
    hedgeCreditBps?: number;
  };
}

export interface TransactionPlan {
  target: Address;
  functionName: string;
  args: readonly unknown[];
}

export interface ReadPlan {
  id: string;
  target: Address;
  functionName: string;
  args: readonly unknown[];
  expected: unknown;
}

export interface VerificationMismatch {
  id: string;
  expected: unknown;
  actual: unknown;
}

export interface VerificationResult {
  ok: boolean;
  mismatches: VerificationMismatch[];
}

export interface VerificationReadError {
  id: string;
  error: string;
}

export interface VerificationCodeError {
  id: string;
  address: Address;
}

export interface LiveVerificationResult extends VerificationResult {
  readErrors: VerificationReadError[];
  missingCode: VerificationCodeError[];
  chainIdMismatch?: { expected: number; actual: number };
}

export interface DeploymentVerificationAdapter {
  read(plan: ReadPlan): Promise<unknown>;
  getCode?(address: Address): Promise<string>;
  chainId?(): Promise<number>;
}

export interface QuoteUpdate {
  side: Side;
  tick: number;
  lots: bigint;
}

export interface BaseMarketDeploymentSpec {
  id: string;
  fundingUpdater: Address;
  oracle: Address;
  executionBandTicks: number;
  initialMarginBps: number;
  takerFeeBps: number;
  makerRebateBps: number;
  collateralUnitsPerLotTick: string;
  oracleMaxAgeSeconds?: number;
}

export interface StandaloneMarketDeploymentSpec extends BaseMarketDeploymentSpec {
  maintenanceMarginBps: number;
  liquidatorRewardBps: number;
}

export interface PortfolioMarketDeploymentSpec extends BaseMarketDeploymentSpec {
  riskGroup: number;
  portfolioMarginBps: number;
  hedgeCreditBps: number;
}

export type DeploymentSpec =
  | {
      schemaVersion: 1;
      mode: "standalone";
      protocolAdmin: Address;
      collateral: { token: Address; decimals: number };
      markets: StandaloneMarketDeploymentSpec[];
    }
  | {
      schemaVersion: 1;
      mode: "portfolio";
      protocolAdmin: Address;
      collateral: { token: Address; decimals: number };
      markets: PortfolioMarketDeploymentSpec[];
    };

export interface DeploymentEnvironment {
  script: "DeployStandalone" | "DeployPortfolio";
  marketId?: string;
  env: Readonly<Record<string, string>>;
}

export interface MarketDeploymentAddresses {
  id: string;
  core: Address;
  advanced: Address;
  marketMaker: Address;
  liquidation?: Address;
  integrationLens: Address;
}

export interface PortfolioDeploymentAddresses {
  coordinator: Address;
  policy: Address;
  vault: Address;
  liquidation: Address;
}

export interface DeploymentManifestMetadata {
  chainId: number;
  deploymentBlock: number;
  packageVersion: string;
}


export class ManifestError extends Error {}

function assertDeploymentMarketBase(
  market: BaseMarketDeploymentSpec,
  prefix: string,
): void {
  if (!market.id) throw new ManifestError(`${prefix}.id is required`);
  assertAddress(market.fundingUpdater, `${prefix}.fundingUpdater`);
  assertAddress(market.oracle, `${prefix}.oracle`);
  assertUint(market.executionBandTicks, `${prefix}.executionBandTicks`, 65535);
  assertUint(market.initialMarginBps, `${prefix}.initialMarginBps`, 10000);
  if (market.initialMarginBps === 0) {
    throw new ManifestError(`${prefix}.initialMarginBps must be greater than zero`);
  }
  assertUint(market.takerFeeBps, `${prefix}.takerFeeBps`, 10000);
  assertUint(market.makerRebateBps, `${prefix}.makerRebateBps`, 10000);
  if (market.makerRebateBps > market.takerFeeBps) {
    throw new ManifestError(`${prefix}.makerRebateBps cannot exceed takerFeeBps`);
  }
  if (!/^[0-9]+$/.test(market.collateralUnitsPerLotTick)) {
    throw new ManifestError(`${prefix}.collateralUnitsPerLotTick must be a positive uint128 string`);
  }
  const accountingScale = BigInt(market.collateralUnitsPerLotTick);
  if (accountingScale === 0n || accountingScale > ((1n << 128n) - 1n)) {
    throw new ManifestError(`${prefix}.collateralUnitsPerLotTick must fit uint128`);
  }
  if (market.oracleMaxAgeSeconds !== undefined) {
    assertUint(market.oracleMaxAgeSeconds, `${prefix}.oracleMaxAgeSeconds`);
  }
}

export function validateDeploymentSpec(spec: DeploymentSpec): DeploymentSpec {
  if (spec.schemaVersion !== 1) throw new ManifestError("unsupported deployment spec schemaVersion");
  assertAddress(spec.protocolAdmin, "protocolAdmin");
  assertAddress(spec.collateral.token, "collateral.token");
  assertUint(spec.collateral.decimals, "collateral.decimals", 255);
  if (!Array.isArray(spec.markets) || spec.markets.length === 0) {
    throw new ManifestError("at least one deployment market is required");
  }
  if (spec.mode === "portfolio" && spec.markets.length > 32) {
    throw new ManifestError("portfolio deployments support at most 32 markets");
  }

  const ids = new Set<string>();
  const groupCredits = new Map<number, number>();
  spec.markets.forEach((market, i) => {
    const prefix = `markets[${i}]`;
    assertDeploymentMarketBase(market, prefix);
    if (ids.has(market.id)) throw new ManifestError(`${prefix}.id must be unique`);
    ids.add(market.id);

    if (spec.mode === "standalone") {
      const standalone = market as StandaloneMarketDeploymentSpec;
      assertUint(standalone.maintenanceMarginBps, `${prefix}.maintenanceMarginBps`, 10000);
      if (
        standalone.maintenanceMarginBps === 0
          || standalone.maintenanceMarginBps >= standalone.initialMarginBps
      ) {
        throw new ManifestError(
          `${prefix}.maintenanceMarginBps must be positive and below initialMarginBps`,
        );
      }
      assertUint(standalone.liquidatorRewardBps, `${prefix}.liquidatorRewardBps`, 1000);
    } else {
      const portfolio = market as PortfolioMarketDeploymentSpec;
      assertUint(portfolio.riskGroup, `${prefix}.riskGroup`, 0xffffffff);
      if (portfolio.riskGroup === 0) {
        throw new ManifestError(`${prefix}.riskGroup must be greater than zero`);
      }
      assertUint(portfolio.portfolioMarginBps, `${prefix}.portfolioMarginBps`, 10000);
      if (portfolio.portfolioMarginBps === 0) {
        throw new ManifestError(`${prefix}.portfolioMarginBps must be greater than zero`);
      }
      assertUint(portfolio.hedgeCreditBps, `${prefix}.hedgeCreditBps`, 10000);
      const prior = groupCredits.get(portfolio.riskGroup);
      if (prior !== undefined && prior !== portfolio.hedgeCreditBps) {
        throw new ManifestError(`${prefix}.hedgeCreditBps must match its risk group`);
      }
      groupCredits.set(portfolio.riskGroup, portfolio.hedgeCreditBps);
    }
  });

  return spec;
}

export function compileDeploymentEnvironments(
  spec: DeploymentSpec,
): DeploymentEnvironment[] {
  validateDeploymentSpec(spec);
  if (spec.mode === "standalone") {
    return spec.markets.map((market) => ({
      script: "DeployStandalone" as const,
      marketId: market.id,
      env: {
        PROTOCOL_ADMIN: spec.protocolAdmin,
        FUNDING_UPDATER: market.fundingUpdater,
        COLLATERAL_TOKEN: spec.collateral.token,
        MARK_ORACLE: market.oracle,
        EXECUTION_BAND_TICKS: String(market.executionBandTicks),
        INITIAL_MARGIN_BPS: String(market.initialMarginBps),
        MAINTENANCE_MARGIN_BPS: String(market.maintenanceMarginBps),
        TAKER_FEE_BPS: String(market.takerFeeBps),
        MAKER_REBATE_BPS: String(market.makerRebateBps),
        LIQUIDATOR_REWARD_BPS: String(market.liquidatorRewardBps),
        COLLATERAL_UNITS_PER_LOT_TICK: market.collateralUnitsPerLotTick,
      },
    }));
  }

  const join = <T>(select: (market: PortfolioMarketDeploymentSpec) => T) =>
    spec.markets.map(select).join(",");
  return [{
    script: "DeployPortfolio",
    env: {
      PROTOCOL_ADMIN: spec.protocolAdmin,
      COLLATERAL_TOKEN: spec.collateral.token,
      FUNDING_UPDATERS: join((market) => market.fundingUpdater),
      MARK_ORACLES: join((market) => market.oracle),
      EXECUTION_BAND_TICKS: join((market) => market.executionBandTicks),
      INITIAL_MARGIN_BPS: join((market) => market.initialMarginBps),
      TAKER_FEE_BPS: join((market) => market.takerFeeBps),
      MAKER_REBATE_BPS: join((market) => market.makerRebateBps),
      COLLATERAL_UNITS_PER_LOT_TICK: join((market) => market.collateralUnitsPerLotTick),
      RISK_GROUPS: join((market) => market.riskGroup),
      PORTFOLIO_MARGIN_BPS: join((market) => market.portfolioMarginBps),
      HEDGE_CREDIT_BPS: join((market) => market.hedgeCreditBps),
    },
  }];
}

export function buildDeploymentManifest(
  spec: DeploymentSpec,
  markets: readonly MarketDeploymentAddresses[],
  metadata: DeploymentManifestMetadata,
  portfolio?: PortfolioDeploymentAddresses,
): DeploymentManifest {
  validateDeploymentSpec(spec);
  assertUint(metadata.chainId, "chainId");
  if (metadata.chainId === 0) throw new ManifestError("chainId must be greater than zero");
  assertUint(metadata.deploymentBlock, "deploymentBlock");
  if (!metadata.packageVersion) throw new ManifestError("packageVersion is required");
  if (markets.length !== spec.markets.length) {
    throw new ManifestError("deployed market address count does not match deployment spec");
  }
  if ((spec.mode === "portfolio") !== Boolean(portfolio)) {
    throw new ManifestError("portfolio deployment addresses must match deployment mode");
  }

  const addresses = new Map(markets.map((market) => [market.id, market]));
  if (addresses.size !== markets.length) throw new ManifestError("deployed market ids must be unique");

  const manifestMarkets = spec.markets.map((market, index): MarketManifest => {
    const deployed = addresses.get(market.id);
    if (!deployed) throw new ManifestError(`missing deployed addresses for ${market.id}`);
    assertAddress(deployed.core, `${market.id}.core`);
    assertAddress(deployed.advanced, `${market.id}.advanced`);
    assertAddress(deployed.marketMaker, `${market.id}.marketMaker`);
    assertAddress(deployed.integrationLens, `${market.id}.integrationLens`);
    if (spec.mode === "standalone") {
      if (!deployed.liquidation) {
        throw new ManifestError(`missing standalone liquidation address for ${market.id}`);
      }
      assertAddress(deployed.liquidation, `${market.id}.liquidation`);
    }

    return {
      id: market.id,
      core: deployed.core,
      advanced: deployed.advanced,
      marketMaker: deployed.marketMaker,
      liquidation: spec.mode === "standalone" ? deployed.liquidation : undefined,
      portfolioLiquidation: spec.mode === "portfolio" ? portfolio?.liquidation : undefined,
      integrationLens: deployed.integrationLens,
      oracle: market.oracle,
      fundingUpdater: market.fundingUpdater,
      portfolioMarketIndex: spec.mode === "portfolio" ? index : undefined,
      scales: { collateralUnitsPerLotTick: market.collateralUnitsPerLotTick },
      parameters: {
        executionBandTicks: market.executionBandTicks,
        initialMarginBps: market.initialMarginBps,
        maintenanceMarginBps:
          spec.mode === "standalone"
            ? (market as StandaloneMarketDeploymentSpec).maintenanceMarginBps
            : undefined,
        takerFeeBps: market.takerFeeBps,
        makerRebateBps: market.makerRebateBps,
        oracleMaxAgeSeconds: market.oracleMaxAgeSeconds,
        riskGroup:
          spec.mode === "portfolio"
            ? (market as PortfolioMarketDeploymentSpec).riskGroup
            : undefined,
        portfolioMarginBps:
          spec.mode === "portfolio"
            ? (market as PortfolioMarketDeploymentSpec).portfolioMarginBps
            : undefined,
        hedgeCreditBps:
          spec.mode === "portfolio"
            ? (market as PortfolioMarketDeploymentSpec).hedgeCreditBps
            : undefined,
      },
    };
  });

  const manifest: DeploymentManifest = {
    schemaVersion: 1,
    chainId: metadata.chainId,
    deploymentBlock: metadata.deploymentBlock,
    packageVersion: metadata.packageVersion,
    protocolAdmin: spec.protocolAdmin,
    collateral: { ...spec.collateral },
    portfolio: portfolio
      ? {
          coordinator: portfolio.coordinator,
          policy: portfolio.policy,
          vault: portfolio.vault,
        }
      : undefined,
    markets: manifestMarkets,
  };
  return validateManifest(manifest);
}

function assertAddress(value: string, field: string): asserts value is Address {
  if (
    !/^0x[0-9a-fA-F]{40}$/.test(value)
      || /^0x0{40}$/i.test(value)
  ) {
    throw new ManifestError(`${field} must be a non-zero 20-byte hex address`);
  }
}

function assertUint(value: number, field: string, max?: number): void {
  if (!Number.isInteger(value) || value < 0 || (max !== undefined && value > max)) {
    throw new ManifestError(`${field} must be an unsigned integer`);
  }
}

export function validateManifest(manifest: DeploymentManifest): DeploymentManifest {
  if (manifest.schemaVersion !== 1) throw new ManifestError("unsupported schemaVersion");
  assertUint(manifest.chainId, "chainId");
  if (manifest.chainId === 0) throw new ManifestError("chainId must be greater than zero");
  assertUint(manifest.deploymentBlock, "deploymentBlock");
  assertAddress(manifest.collateral.token, "collateral.token");
  assertUint(manifest.collateral.decimals, "collateral.decimals", 255);
  if (!manifest.packageVersion) throw new ManifestError("packageVersion is required");
  assertAddress(manifest.protocolAdmin, "protocolAdmin");
  if (!Array.isArray(manifest.markets) || manifest.markets.length === 0) {
    throw new ManifestError("at least one market is required");
  }

  if (manifest.portfolio) {
    assertAddress(manifest.portfolio.coordinator, "portfolio.coordinator");
    assertAddress(manifest.portfolio.policy, "portfolio.policy");
    assertAddress(manifest.portfolio.vault, "portfolio.vault");
  }

  const ids = new Set<string>();
  const portfolioGroupCredits = new Map<number, number>();
  for (const [i, market] of manifest.markets.entries()) {
    const prefix = `markets[${i}]`;
    if (!market.id || ids.has(market.id)) {
      throw new ManifestError(`${prefix}.id must be non-empty and unique`);
    }
    ids.add(market.id);
    assertAddress(market.core, `${prefix}.core`);
    assertAddress(market.advanced, `${prefix}.advanced`);
    assertAddress(market.oracle, `${prefix}.oracle`);
    assertAddress(market.fundingUpdater, `${prefix}.fundingUpdater`);
    if (market.marketMaker) assertAddress(market.marketMaker, `${prefix}.marketMaker`);
    if (market.liquidation) assertAddress(market.liquidation, `${prefix}.liquidation`);
    if (market.portfolioLiquidation) {
      assertAddress(market.portfolioLiquidation, `${prefix}.portfolioLiquidation`);
    }
    if (market.integrationLens) {
      assertAddress(market.integrationLens, `${prefix}.integrationLens`);
    }
    if (market.portfolioMarketIndex !== undefined) {
      assertUint(market.portfolioMarketIndex, `${prefix}.portfolioMarketIndex`, 255);
      if (!manifest.portfolio) {
        throw new ManifestError(`${prefix}.portfolioMarketIndex requires portfolio config`);
      }
    }
    if (
      typeof market.scales.collateralUnitsPerLotTick !== "string"
        || !/^[0-9]+$/.test(market.scales.collateralUnitsPerLotTick)
    ) {
      throw new ManifestError(`${prefix}.scales.collateralUnitsPerLotTick must be a uint string`);
    }
    assertUint(market.parameters.executionBandTicks, `${prefix}.parameters.executionBandTicks`, 65535);
    assertUint(market.parameters.initialMarginBps, `${prefix}.parameters.initialMarginBps`, 10000);
    if (market.parameters.maintenanceMarginBps !== undefined) {
      assertUint(
        market.parameters.maintenanceMarginBps,
        `${prefix}.parameters.maintenanceMarginBps`,
        10000,
      );
    }
    assertUint(market.parameters.takerFeeBps, `${prefix}.parameters.takerFeeBps`, 10000);
    assertUint(market.parameters.makerRebateBps, `${prefix}.parameters.makerRebateBps`, 10000);
    if (market.parameters.makerRebateBps > market.parameters.takerFeeBps) {
      throw new ManifestError(`${prefix}.parameters.makerRebateBps cannot exceed takerFeeBps`);
    }
    if (market.parameters.oracleMaxAgeSeconds !== undefined) {
      assertUint(market.parameters.oracleMaxAgeSeconds, `${prefix}.parameters.oracleMaxAgeSeconds`);
    }
    if (market.portfolioMarketIndex !== undefined) {
      if (
        market.parameters.riskGroup === undefined
          || market.parameters.portfolioMarginBps === undefined
          || market.parameters.hedgeCreditBps === undefined
      ) {
        throw new ManifestError(`${prefix}.parameters requires portfolio risk settings`);
      }
      assertUint(market.parameters.riskGroup, `${prefix}.parameters.riskGroup`, 0xffffffff);
      if (market.parameters.riskGroup === 0) {
        throw new ManifestError(`${prefix}.parameters.riskGroup must be greater than zero`);
      }
      assertUint(
        market.parameters.portfolioMarginBps,
        `${prefix}.parameters.portfolioMarginBps`,
        10000,
      );
      if (market.parameters.portfolioMarginBps === 0) {
        throw new ManifestError(
          `${prefix}.parameters.portfolioMarginBps must be greater than zero`,
        );
      }
      assertUint(
        market.parameters.hedgeCreditBps,
        `${prefix}.parameters.hedgeCreditBps`,
        10000,
      );
      const priorCredit = portfolioGroupCredits.get(market.parameters.riskGroup);
      if (
        priorCredit !== undefined
          && priorCredit !== market.parameters.hedgeCreditBps
      ) {
        throw new ManifestError(
          `${prefix}.parameters.hedgeCreditBps must match its risk group`,
        );
      }
      portfolioGroupCredits.set(
        market.parameters.riskGroup,
        market.parameters.hedgeCreditBps,
      );
    }
  }

  return manifest;
}

export class OrderBookSDK {
  readonly manifest: DeploymentManifest;

  constructor(manifest: DeploymentManifest) {
    this.manifest = validateManifest(manifest);
  }

  market(id: string): MarketManifest {
    const market = this.manifest.markets.find((item) => item.id === id);
    if (!market) throw new ManifestError(`unknown market: ${id}`);
    return market;
  }

  deploymentVerificationPlan(): ReadPlan[] {
    const plans: ReadPlan[] = [];
    const zero = "0x0000000000000000000000000000000000000000" as Address;

    for (const market of this.manifest.markets) {
      const prefix = `market:${market.id}`;
      const portfolioController = market.portfolioMarketIndex !== undefined
        ? this.requirePortfolioCoordinator()
        : zero;

      plans.push(
        {
          id: `${prefix}:core.owner`,
          target: market.core,
          functionName: "owner",
          args: [],
          expected: this.manifest.protocolAdmin,
        },
        {
          id: `${prefix}:core.fundingUpdater`,
          target: market.core,
          functionName: "fundingUpdater",
          args: [],
          expected: market.fundingUpdater,
        },
        {
          id: `${prefix}:core.markOracle`,
          target: market.core,
          functionName: "markOracle",
          args: [],
          expected: market.oracle,
        },
        {
          id: `${prefix}:core.initialMarginBps`,
          target: market.core,
          functionName: "initialMarginBps",
          args: [],
          expected: BigInt(market.parameters.initialMarginBps),
        },
        {
          id: `${prefix}:core.advancedModule`,
          target: market.core,
          functionName: "advancedModule",
          args: [],
          expected: market.advanced,
        },
        {
          id: `${prefix}:core.portfolioController`,
          target: market.core,
          functionName: "portfolioController",
          args: [],
          expected: portfolioController,
        },
        {
          id: `${prefix}:core.accountingScale`,
          target: market.core,
          functionName: "notionalValue",
          args: [1n, 1],
          expected: BigInt(market.scales.collateralUnitsPerLotTick),
        },
        {
          id: `${prefix}:advanced.owner`,
          target: market.advanced,
          functionName: "owner",
          args: [],
          expected: this.manifest.protocolAdmin,
        },
        {
          id: `${prefix}:advanced.core`,
          target: market.advanced,
          functionName: "core",
          args: [],
          expected: market.core,
        },
        {
          id: `${prefix}:advanced.marketMakerModule`,
          target: market.advanced,
          functionName: "marketMakerModule",
          args: [],
          expected: market.marketMaker ?? zero,
        },
        {
          id: `${prefix}:advanced.liquidationModule`,
          target: market.advanced,
          functionName: "liquidationModule",
          args: [],
          expected: market.portfolioLiquidation ?? market.liquidation ?? zero,
        },
        {
          id: `${prefix}:advanced.portfolioController`,
          target: market.advanced,
          functionName: "portfolioController",
          args: [],
          expected: portfolioController,
        },
      );

      if (market.portfolioMarketIndex !== undefined) {
        const coordinator = this.requirePortfolioCoordinator();
        plans.push(
          {
            id: `${prefix}:advanced.portfolioMarketIndex`,
            target: market.advanced,
            functionName: "portfolioMarketIndex",
            args: [],
            expected: BigInt(market.portfolioMarketIndex),
          },
          {
            id: `${prefix}:coordinator.marketSlot`,
            target: coordinator,
            functionName: "markets",
            args: [BigInt(market.portfolioMarketIndex)],
            expected: [market.core, market.advanced],
          },
          {
            id: `${prefix}:policy.marketSlot`,
            target: this.manifest.portfolio!.policy,
            functionName: "markets",
            args: [BigInt(market.portfolioMarketIndex)],
            expected: [
              market.core,
              BigInt(market.parameters.riskGroup!),
              BigInt(market.parameters.portfolioMarginBps!),
              BigInt(market.parameters.hedgeCreditBps!),
            ],
          },
        );
      }

      if (market.marketMaker) {
        plans.push(
          {
            id: `${prefix}:marketMaker.core`,
            target: market.marketMaker,
            functionName: "core",
            args: [],
            expected: market.core,
          },
          {
            id: `${prefix}:marketMaker.gateway`,
            target: market.marketMaker,
            functionName: "gateway",
            args: [],
            expected: market.advanced,
          },
        );
      }

      if (market.integrationLens) {
        plans.push(
          {
            id: `${prefix}:lens.core`,
            target: market.integrationLens,
            functionName: "core",
            args: [],
            expected: market.core,
          },
          {
            id: `${prefix}:lens.advanced`,
            target: market.integrationLens,
            functionName: "advanced",
            args: [],
            expected: market.advanced,
          },
        );
      }

      if (
        market.portfolioMarketIndex === undefined
          && market.liquidation
          && market.parameters.maintenanceMarginBps !== undefined
      ) {
        plans.push(
          {
            id: `${prefix}:liquidation.owner`,
            target: market.liquidation,
            functionName: "owner",
            args: [],
            expected: this.manifest.protocolAdmin,
          },
          {
            id: `${prefix}:liquidation.core`,
            target: market.liquidation,
            functionName: "core",
            args: [],
            expected: market.core,
          },
          {
            id: `${prefix}:liquidation.gateway`,
            target: market.liquidation,
            functionName: "gateway",
            args: [],
            expected: market.advanced,
          },
          {
            id: `${prefix}:liquidation.maintenanceMarginBps`,
            target: market.liquidation,
            functionName: "maintenanceMarginBps",
            args: [],
            expected: BigInt(market.parameters.maintenanceMarginBps),
          },
        );
      }
    }

    if (this.manifest.portfolio) {
      const { coordinator, policy, vault } = this.manifest.portfolio;
      plans.push(
        {
          id: "portfolio:policy.owner",
          target: policy,
          functionName: "owner",
          args: [],
          expected: this.manifest.protocolAdmin,
        },
        {
          id: "portfolio:vault.owner",
          target: vault,
          functionName: "owner",
          args: [],
          expected: this.manifest.protocolAdmin,
        },
        {
          id: "portfolio:vault.collateralToken",
          target: vault,
          functionName: "collateralToken",
          args: [],
          expected: this.manifest.collateral.token,
        },
        {
          id: "portfolio:vault.controller",
          target: vault,
          functionName: "controller",
          args: [],
          expected: coordinator,
        },
        {
          id: "portfolio:policy.sharedCollateralVault",
          target: policy,
          functionName: "sharedCollateralVault",
          args: [],
          expected: vault,
        },
        {
          id: "portfolio:coordinator.policy",
          target: coordinator,
          functionName: "policy",
          args: [],
          expected: policy,
        },
        {
          id: "portfolio:coordinator.vault",
          target: coordinator,
          functionName: "vault",
          args: [],
          expected: vault,
        },
      );
    }

    return plans;
  }

  take(
    marketId: string,
    side: Side,
    limitTick: number,
    lots: bigint,
    policy: FillPolicy = 0,
  ): TransactionPlan {
    const market = this.market(marketId);
    if (market.portfolioMarketIndex !== undefined) {
      const coordinator = this.requirePortfolioCoordinator();
      return {
        target: coordinator,
        functionName: "take",
        args: [BigInt(market.portfolioMarketIndex), side, limitTick, lots, policy],
      };
    }
    return {
      target: market.core,
      functionName: "take",
      args: [side, limitTick, lots, policy],
    };
  }

  addLiquidity(
    marketId: string,
    side: Side,
    tick: number,
    lots: bigint,
  ): TransactionPlan {
    const market = this.market(marketId);
    if (market.portfolioMarketIndex !== undefined) {
      const coordinator = this.requirePortfolioCoordinator();
      return {
        target: coordinator,
        functionName: "addLiquidity",
        args: [BigInt(market.portfolioMarketIndex), side, tick, lots],
      };
    }
    return {
      target: market.core,
      functionName: "addLiquidity",
      args: [side, tick, lots],
    };
  }

  removeLiquidity(
    marketId: string,
    side: Side,
    tick: number,
    generation: number,
    shares: bigint,
  ): TransactionPlan {
    const market = this.market(marketId);
    if (market.portfolioMarketIndex !== undefined) {
      const coordinator = this.requirePortfolioCoordinator();
      return {
        target: coordinator,
        functionName: "removeLiquidity",
        args: [BigInt(market.portfolioMarketIndex), side, tick, generation, shares],
      };
    }
    return {
      target: market.core,
      functionName: "removeShares",
      args: [side, tick, shares],
    };
  }

  deposit(marketId: string, amount: bigint): TransactionPlan {
    const market = this.market(marketId);
    if (market.portfolioMarketIndex !== undefined) {
      if (!this.manifest.portfolio) {
        throw new ManifestError("portfolio market requires portfolio config");
      }
      return {
        target: this.manifest.portfolio.vault,
        functionName: "deposit",
        args: [amount],
      };
    }
    return {
      target: market.core,
      functionName: "depositCollateral",
      args: [amount],
    };
  }

  withdraw(marketId: string, amount: bigint): TransactionPlan {
    const market = this.market(marketId);
    if (market.portfolioMarketIndex !== undefined) {
      return {
        target: this.requirePortfolioCoordinator(),
        functionName: "withdraw",
        args: [amount],
      };
    }
    return {
      target: market.core,
      functionName: "withdrawCollateral",
      args: [amount],
    };
  }

  takeReduceOnly(
    marketId: string,
    side: Side,
    limitTick: number,
    lots: bigint,
    policy: FillPolicy = 0,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "takeReduceOnly",
      args: [side, limitTick, lots, policy],
    };
  }

  takeMinFill(
    marketId: string,
    side: Side,
    limitTick: number,
    lots: bigint,
    minFillLots: bigint,
    reduceOnly = false,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "takeMinFill",
      args: [side, limitTick, lots, minFillLots, reduceOnly],
    };
  }

  placeConditional(
    marketId: string,
    side: Side,
    triggerAboveOrEqual: boolean,
    triggerTick: number,
    limitTick: number,
    lots: bigint,
    policy: FillPolicy = 0,
    reduceOnly = false,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "placeConditionalOrder",
      args: [side, triggerAboveOrEqual, triggerTick, limitTick, lots, policy, reduceOnly],
    };
  }

  placeTriggeredLimit(
    marketId: string,
    side: Side,
    triggerAboveOrEqual: boolean,
    triggerTick: number,
    limitTick: number,
    lots: bigint,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "placeTriggeredLimitOrder",
      args: [side, triggerAboveOrEqual, triggerTick, limitTick, lots],
    };
  }

  placeTriggeredPostOnly(
    marketId: string,
    side: Side,
    triggerAboveOrEqual: boolean,
    triggerTick: number,
    limitTick: number,
    lots: bigint,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "placeTriggeredPostOnlyOrder",
      args: [side, triggerAboveOrEqual, triggerTick, limitTick, lots],
    };
  }

  placeTrailing(
    marketId: string,
    side: Side,
    trailTicks: number,
    limitTick: number,
    lots: bigint,
    policy: FillPolicy = 0,
    reduceOnly = false,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "placeTrailingOrder",
      args: [side, trailTicks, limitTick, lots, policy, reduceOnly],
    };
  }

  linkOCO(
    marketId: string,
    firstOrderId: bigint,
    secondOrderId: bigint,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "linkOCO",
      args: [firstOrderId, secondOrderId],
    };
  }

  linkOTO(
    marketId: string,
    parentOrderId: bigint,
    childOrderId: bigint,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "linkOTO",
      args: [parentOrderId, childOrderId],
    };
  }

  setConditionalExpiry(
    marketId: string,
    orderId: bigint,
    expiry: bigint,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "setConditionalExpiry",
      args: [orderId, expiry],
    };
  }

  cancelConditional(marketId: string, orderId: bigint): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "cancelConditionalOrder",
      args: [orderId],
    };
  }

  setTrailingExpiry(
    marketId: string,
    orderId: bigint,
    expiry: bigint,
  ): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "setTrailingExpiry",
      args: [orderId, expiry],
    };
  }

  cancelTrailing(marketId: string, orderId: bigint): TransactionPlan {
    const market = this.market(marketId);
    return {
      target: market.advanced,
      functionName: "cancelTrailingOrder",
      args: [orderId],
    };
  }

  replaceQuotesPacked(marketId: string, updates: readonly QuoteUpdate[]): TransactionPlan {
    const market = this.market(marketId);
    if (!market.marketMaker) throw new ManifestError(`${marketId} has no marketMaker module`);
    return {
      target: market.marketMaker,
      functionName: "batchReplaceQuotesPacked",
      args: [encodePackedQuoteUpdates(updates)],
    };
  }

  private requirePortfolioCoordinator(): Address {
    if (!this.manifest.portfolio) {
      throw new ManifestError("portfolio market requires portfolio config");
    }
    return this.manifest.portfolio.coordinator;
  }
}

export function encodePackedQuoteUpdates(updates: readonly QuoteUpdate[]): Hex {
  if (updates.length === 0) throw new RangeError("at least one quote update is required");

  let previousKey = -1;
  let out = "0x";
  for (const update of updates) {
    if (update.side !== 0 && update.side !== 1) throw new RangeError("side must be 0 or 1");
    assertUint(update.tick, "tick", 65535);
    if (update.lots < 0n || update.lots > ((1n << 96n) - 1n)) {
      throw new RangeError("lots must fit uint96");
    }

    const key = (update.side << 16) | update.tick;
    if (key <= previousKey) {
      throw new RangeError("quote updates must be strictly sorted by side/tick");
    }
    previousKey = key;

    const word =
      update.lots
      | (BigInt(update.tick) << 96n)
      | (BigInt(update.side) << 112n);
    out += word.toString(16).padStart(32, "0");
  }
  return out as Hex;
}

function verificationValueEqual(expected: unknown, actual: unknown): boolean {
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length < expected.length) return false;
    return expected.every((value, index) => verificationValueEqual(value, actual[index]));
  }
  if (typeof expected === "string" && /^0x[0-9a-fA-F]{40}$/.test(expected)) {
    return typeof actual === "string" && actual.toLowerCase() === expected.toLowerCase();
  }
  if (typeof expected === "bigint") {
    if (typeof actual === "bigint") return actual === expected;
    if (typeof actual === "number" && Number.isSafeInteger(actual)) {
      return BigInt(actual) === expected;
    }
    if (typeof actual === "string" && /^[0-9]+$/.test(actual)) {
      return BigInt(actual) === expected;
    }
    return false;
  }
  return Object.is(expected, actual);
}

export function verifyDeploymentResults(
  plans: readonly ReadPlan[],
  results: Readonly<Record<string, unknown>>,
): VerificationResult {
  const mismatches: VerificationMismatch[] = [];
  const ids = new Set<string>();

  for (const plan of plans) {
    if (ids.has(plan.id)) throw new Error(`duplicate verification plan id: ${plan.id}`);
    ids.add(plan.id);

    if (!(plan.id in results)) {
      mismatches.push({ id: plan.id, expected: plan.expected, actual: undefined });
      continue;
    }

    const actual = results[plan.id];
    if (!verificationValueEqual(plan.expected, actual)) {
      mismatches.push({ id: plan.id, expected: plan.expected, actual });
    }
  }

  return { ok: mismatches.length === 0, mismatches };
}

function deploymentAddresses(manifest: DeploymentManifest): { id: string; address: Address }[] {
  const entries: { id: string; address: Address }[] = [];
  const push = (id: string, address: Address | undefined) => {
    if (address) entries.push({ id, address });
  };

  push("collateral.token", manifest.collateral.token);

  if (manifest.portfolio) {
    push("portfolio.coordinator", manifest.portfolio.coordinator);
    push("portfolio.policy", manifest.portfolio.policy);
    push("portfolio.vault", manifest.portfolio.vault);
  }
  for (const market of manifest.markets) {
    const prefix = `market:${market.id}`;
    push(`${prefix}.core`, market.core);
    push(`${prefix}.advanced`, market.advanced);
    push(`${prefix}.marketMaker`, market.marketMaker);
    push(`${prefix}.liquidation`, market.liquidation);
    push(`${prefix}.portfolioLiquidation`, market.portfolioLiquidation);
    push(`${prefix}.integrationLens`, market.integrationLens);
    push(`${prefix}.oracle`, market.oracle);
  }
  return entries;
}

export async function executeDeploymentVerification(
  manifest: DeploymentManifest,
  adapter: DeploymentVerificationAdapter,
): Promise<LiveVerificationResult> {
  const sdk = new OrderBookSDK(manifest);
  const plans = sdk.deploymentVerificationPlan();
  const results: Record<string, unknown> = {};
  const readErrors: VerificationReadError[] = [];
  const missingCode: VerificationCodeError[] = [];
  let chainIdMismatch: { expected: number; actual: number } | undefined;

  if (adapter.chainId) {
    try {
      const actual = await adapter.chainId();
      if (actual !== manifest.chainId) {
        chainIdMismatch = { expected: manifest.chainId, actual };
      }
    } catch (error) {
      readErrors.push({
        id: "preflight.chainId",
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  if (adapter.getCode) {
    const seen = new Set<string>();
    for (const entry of deploymentAddresses(manifest)) {
      const normalized = entry.address.toLowerCase();
      if (seen.has(normalized)) continue;
      seen.add(normalized);
      try {
        const code = await adapter.getCode(entry.address);
        if (typeof code !== "string" || !/^0x[0-9a-fA-F]*$/.test(code) || code === "0x") {
          missingCode.push(entry);
        }
      } catch (error) {
        readErrors.push({
          id: `preflight.code:${entry.id}`,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }

  for (const plan of plans) {
    try {
      results[plan.id] = await adapter.read(plan);
    } catch (error) {
      readErrors.push({
        id: plan.id,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const compared = verifyDeploymentResults(plans, results);
  return {
    ok:
      compared.ok
      && readErrors.length === 0
      && missingCode.length === 0
      && chainIdMismatch === undefined,
    mismatches: compared.mismatches,
    readErrors,
    missingCode,
    chainIdMismatch,
  };
}


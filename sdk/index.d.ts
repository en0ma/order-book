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

export declare class ManifestError extends Error {}

export declare function validateManifest(
  manifest: DeploymentManifest,
): DeploymentManifest;

export declare function validateDeploymentSpec(spec: DeploymentSpec): DeploymentSpec;

export declare function compileDeploymentEnvironments(
  spec: DeploymentSpec,
): DeploymentEnvironment[];

export declare function buildDeploymentManifest(
  spec: DeploymentSpec,
  markets: readonly MarketDeploymentAddresses[],
  metadata: DeploymentManifestMetadata,
  portfolio?: PortfolioDeploymentAddresses,
): DeploymentManifest;


export declare class OrderBookSDK {
  readonly manifest: DeploymentManifest;

  constructor(manifest: DeploymentManifest);

  market(id: string): MarketManifest;

  deploymentVerificationPlan(): ReadPlan[];

  take(
    marketId: string,
    side: Side,
    limitTick: number,
    lots: bigint,
    policy?: FillPolicy,
  ): TransactionPlan;

  addLiquidity(
    marketId: string,
    side: Side,
    tick: number,
    lots: bigint,
  ): TransactionPlan;

  removeLiquidity(
    marketId: string,
    side: Side,
    tick: number,
    generation: number,
    shares: bigint,
  ): TransactionPlan;

  deposit(marketId: string, amount: bigint): TransactionPlan;
  withdraw(marketId: string, amount: bigint): TransactionPlan;

  takeReduceOnly(
    marketId: string,
    side: Side,
    limitTick: number,
    lots: bigint,
    policy?: FillPolicy,
  ): TransactionPlan;

  takeMinFill(
    marketId: string,
    side: Side,
    limitTick: number,
    lots: bigint,
    minFillLots: bigint,
    reduceOnly?: boolean,
  ): TransactionPlan;

  placeConditional(
    marketId: string,
    side: Side,
    triggerAboveOrEqual: boolean,
    triggerTick: number,
    limitTick: number,
    lots: bigint,
    policy?: FillPolicy,
    reduceOnly?: boolean,
  ): TransactionPlan;

  placeTriggeredLimit(
    marketId: string,
    side: Side,
    triggerAboveOrEqual: boolean,
    triggerTick: number,
    limitTick: number,
    lots: bigint,
  ): TransactionPlan;

  placeTriggeredPostOnly(
    marketId: string,
    side: Side,
    triggerAboveOrEqual: boolean,
    triggerTick: number,
    limitTick: number,
    lots: bigint,
  ): TransactionPlan;

  placeTrailing(
    marketId: string,
    side: Side,
    trailTicks: number,
    limitTick: number,
    lots: bigint,
    policy?: FillPolicy,
    reduceOnly?: boolean,
  ): TransactionPlan;

  linkOCO(
    marketId: string,
    firstOrderId: bigint,
    secondOrderId: bigint,
  ): TransactionPlan;

  linkOTO(
    marketId: string,
    parentOrderId: bigint,
    childOrderId: bigint,
  ): TransactionPlan;

  setConditionalExpiry(
    marketId: string,
    orderId: bigint,
    expiry: bigint,
  ): TransactionPlan;

  cancelConditional(marketId: string, orderId: bigint): TransactionPlan;

  setTrailingExpiry(
    marketId: string,
    orderId: bigint,
    expiry: bigint,
  ): TransactionPlan;

  cancelTrailing(marketId: string, orderId: bigint): TransactionPlan;

  replaceQuotesPacked(
    marketId: string,
    updates: readonly QuoteUpdate[],
  ): TransactionPlan;
}

export declare function encodePackedQuoteUpdates(
  updates: readonly QuoteUpdate[],
): Hex;

export declare function verifyDeploymentResults(
  plans: readonly ReadPlan[],
  results: Readonly<Record<string, unknown>>,
): VerificationResult;

export declare function executeDeploymentVerification(
  manifest: DeploymentManifest,
  adapter: DeploymentVerificationAdapter,
): Promise<LiveVerificationResult>;

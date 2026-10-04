export type Address = `0x${string}`;
export type Hex = `0x${string}`;
export type Side = 0 | 1;
export type FillPolicy = 0 | 1;

export interface DeploymentManifest {
  schemaVersion: 1;
  chainId: number;
  deploymentBlock: number;
  packageVersion: string;
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

export interface QuoteUpdate {
  side: Side;
  tick: number;
  lots: bigint;
}

export declare class ManifestError extends Error {}

export declare function validateManifest(
  manifest: DeploymentManifest,
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

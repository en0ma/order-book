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

export interface QuoteUpdate {
  side: Side;
  tick: number;
  lots: bigint;
}

export class ManifestError extends Error {}

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
  if (!Array.isArray(manifest.markets) || manifest.markets.length === 0) {
    throw new ManifestError("at least one market is required");
  }

  if (manifest.portfolio) {
    assertAddress(manifest.portfolio.coordinator, "portfolio.coordinator");
    assertAddress(manifest.portfolio.policy, "portfolio.policy");
    assertAddress(manifest.portfolio.vault, "portfolio.vault");
  }

  const ids = new Set<string>();
  for (const [i, market] of manifest.markets.entries()) {
    const prefix = `markets[${i}]`;
    if (!market.id || ids.has(market.id)) {
      throw new ManifestError(`${prefix}.id must be non-empty and unique`);
    }
    ids.add(market.id);
    assertAddress(market.core, `${prefix}.core`);
    assertAddress(market.advanced, `${prefix}.advanced`);
    assertAddress(market.oracle, `${prefix}.oracle`);
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

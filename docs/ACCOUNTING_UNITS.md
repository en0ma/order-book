# Accounting Units

The deployable core stores collateral balances in the collateral token's smallest unit, while order size is expressed in lots and price is expressed in integer ticks.

To make those domains explicit, `OrderBookCore` exposes a one-time deployment setting:

```
collateralUnitsPerLotTick
```

Every economic notional is computed as:

```
notional = lots * tick * collateralUnitsPerLotTick
```

The result is denominated in collateral-token smallest units and is used consistently for:

- trade cashflow
- mark-to-market equity
- initial margin
- maintenance margin
- taker fees
- maker rebates
- liquidation rewards

## Deriving the scale

For a quote-denominated collateral token:

```
collateralUnitsPerLotTick
  = lotSizeInBase
  * tickSizeInQuotePerBase
  * collateralSmallestUnitsPerQuote
```

The deployment must choose lot size and tick size so this product is an exact positive integer. This deliberately avoids fractional rounding inside the matching and maker-attribution paths.

Example: USDC has 6 decimals, one lot is 0.001 base units, and one tick is 1 quote unit per base unit.

```
0.001 * 1 * 1_000_000 = 1_000
```

So `collateralUnitsPerLotTick = 1_000`.

## Locking

The core defaults to scale `1` for backwards-compatible tests and reference deployments.

A production deployment should call `configureAccountingUnitScale(...)` before accepting collateral. The first explicit configuration, collateral deposit, or insurance deposit locks the scale permanently.

This prevents live positions, cashflow, margin, or protocol reserves from being reinterpreted under a different unit system.

## Scope

This scale assumes collateral and PnL share the same quote denomination.

If the collateral asset is not the quote asset, production accounting requires a separate collateral-to-quote conversion/risk layer. That conversion should not be hidden inside `collateralUnitsPerLotTick`, because its value would be market-dependent rather than an immutable unit definition.

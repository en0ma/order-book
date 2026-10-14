# List a Perpetual Market

Use this procedure to add a market to a DEX that uses the order-book contracts. A market is a **perpetual instrument**, not a spot token pair. Listing a token as an underlying asset does not mint or transfer that underlying token. Collateral is a separate ERC-20 selected for the deployment.

![market listing lifecycle](/docs/assets/diagrams/market-listing-lifecycle.svg)

[Edit the diagram source](https://github.com/en0ma/order-book/blob/docs/site-quality-gates-and-visuals/docs/assets/diagrams/source/market-listing-lifecycle.drawio).

## 1. Choose the deployment mode

- **Standalone:** Deploy a new `OrderBookCore` and its associated modules for each market. Collateral is held by that Core. This is the least coupled listing route.
- **Portfolio:** The coordinator takes a fixed market configuration array at deployment. New markets are **not** added by a documented dynamic registration method. To add another portfolio market, design an explicit migration and a new coordinator deployment. Do not claim that adding a market is a routine admin transaction in portfolio mode.

## 2. Define the listing specification

| Item | Team decision | Implementation effect |
| --- | --- | --- |
| Market name and ID | Assign unique display symbol and manifest market ID | Frontend/indexer routing; no on-chain token listing registry |
| Chain ID | Select target EVM chain | Deployment manifest and RPC verification |
| Collateral asset | Approve an ERC-20 and its decimals/behavior | `COLLATERAL_TOKEN` constructor input; custody checks |
| Underlying reference | Select supported price/oracle adapter | `MARK_ORACLE`; the underlying is not deposited |
| Price ticks | Define external price scale and tick-to-price convention | Oracle current mark, 65,536 tick range and execution policy |
| Lot units | Define contract lot size and accounting scale | `COLLATERAL_UNITS_PER_LOT_TICK`; no generic runtime tick-size setter |
| Risk | Set initial and maintenance margin and execution band | Deployment arguments and liquidation policy |
| Fees | Set taker fee, maker rebate, liquidation reward | Constructor/deployment configuration |
| Funding | Set signer/authority, formula and update controls | `FUNDING_UPDATER`; wrapper optional |
| Oracle history | Supply extrema input where trailing orders require it | Advanced order behavior and keeper eligibility |
| Liquidity | Secure initial maker participation | Orders are supplied by independent market makers |

See [Parameter Reference](/docs/PARAMETER_REFERENCE) for exact mutability, units and bounds. Do not confuse a listed underlying token with the collateral asset.

## 3. Validate the listing configuration

1. Copy the **shape** of `deployments/spec/example.json`. Replace every placeholder value. Validate against `deployments/spec/schema/v1.json`.
2. Run `validateDeploymentSpec(spec)` from the SDK. Use `compileDeploymentEnvironments(spec)` to create Foundry environment values.
3. Obtain a risk review for oracle decimals, spread, volatility, contract size, margin and liquidation depth.
4. Verify that the collateral token's transfer semantics are compatible with Core's custody checks. Do not assume fee-on-transfer tokens are accepted.
5. Simulate gap moves, oracle staleness, loss of maker liquidity, funding outliers and bad debt.

## 4. Deploy a standalone market

The reference deployment script is `script/DeployStandalone.s.sol:DeployStandalone`. Its environment inputs are:

```text
PROTOCOL_ADMIN
FUNDING_UPDATER
COLLATERAL_TOKEN
MARK_ORACLE
EXECUTION_BAND_TICKS
INITIAL_MARGIN_BPS
MAINTENANCE_MARGIN_BPS
TAKER_FEE_BPS
MAKER_REBATE_BPS
LIQUIDATOR_REWARD_BPS
COLLATERAL_UNITS_PER_LOT_TICK
```

Do not paste private keys into this document or a deployment manifest. Set the broadcaster through your team's Foundry signing process.

```sh
forge test -vvv
forge script script/DeployStandalone.s.sol:DeployStandalone --rpc-url "$RPC_URL"
# After simulation and approval, run with the team's secure broadcaster and --broadcast.
```

The script deploys `OrderBookCore`, `AdvancedOrderModule`, `ExecutionStrategyModule`, `MarketMakerModule`, `LiquidationModule` and `IntegrationLens`. It configures their wiring, sets the funding updater, and transfers Core, Advanced and Liquidation ownership to `PROTOCOL_ADMIN`.

## 5. Publish and verify the market

1. Record actual contract addresses and the deployment block.
2. Build a canonical manifest with `buildDeploymentManifest`.
3. Run the SDK's live deployment verifier, including the exact deployed runtime-bytecode attestation.
4. Confirm owner, funding updater, oracle, margin and module wiring on-chain.
5. Add the new market to your own API/frontend routing, symbol map and indexer manifest.
6. Start event replay from the recorded deployment block. Do not reuse another market's checkpoint.
7. Onboard makers and verify quote add, cancel, partial-fill settlement and funding accounting.
8. Test taker orders, reduce-only close, liquidation cleanup and custody withdrawal before inviting users.

## 6. Operate or retire the market

Track mark freshness, realized funding, maker depth, order count, insurance funds and outstanding liquidation positions. Because the standalone Core has no documented generic in-place market-delete switch, market retirement is an **operator-led process**: stop new risk through authorized pause, cancel orders, close risk with available liquidity, settle claims, support permitted withdrawals and archive the final manifest. Never promise forced settlement when opposing book liquidity is absent.

Read [Governance and Keys](/docs/GOVERNANCE_AND_KEYS), [Integration Flows](/docs/INTEGRATION_FLOWS) and [Team Handbook](/docs/TEAM_HANDBOOK).


### Portfolio retirement and migration safety gate

Portfolio market sets and their vault/controller links are immutable in the current deployment model.
There is **no authorized on-chain portfolio market retirement, collateral migration or
controller replacement transaction**. An administrator must not re-label an old market
as retired or transfer its accounted custody into a new vault merely because orders appear
closed in an indexer.

`PortfolioRetirementPreflight` offers two deliberately separate fail-closed *read-only*
checks: `assertConfigurationAndReservesClear()` rejects live vault collateral, physical
custody, nonzero market fees/insurance and inconsistent Core/policy/controller wiring;
`assertAccountsClear(sortedUniqueAccounts)` rejects nonzero deposits/withdrawal checkpoints,
locks, signed claims, open position envelopes, market cash claims, maker quotes and
conditional/trailing/strategy inventory exposed by the gateway.

**The preflight cannot prove the supplied accounts enumerate all historical traders or
lazy maker claimants.** A passing sample or incomplete list is not a global solvency
certificate, a deployment authorization or a substitute for a complete, reorg-safe
event replay and independent liability reconciliation. In particular, a position can
settle without eliminating an outstanding claim. A new coordinator/vault deployment
must remain blocked until a separately reviewed complete migration mechanism,
claimant enumeration and an audited, exact-head liability proof exist. Old claims
must never be silently assumed to have moved.

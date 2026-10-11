# Market Parameters and Change Control

This page maps the deployment inputs and privileged setters to actual Solidity entrypoints. **Basis points** are parts per 10,000. **Ticks** are discrete order-book price indices. **Lots** are integer quantity units. `X18` means a fixed-point factor of 10^18.

## Core and liquidation settings

| Setting | Source | When it changes | Who can change it |
| --- | --- | --- | --- |
| Collateral ERC-20 | `OrderBookCore` constructor, `collateralToken_` | Immutable Core instance | New deployment |
| Oracle contract | Core constructor, `markOracle_` | Immutable Core instance | New deployment |
| Execution band in ticks | Core constructor, `executionBandTicks_` | Immutable Core instance | New deployment |
| Initial margin, bps | Core constructor, `initialMarginBps_` | Immutable Core instance | New deployment |
| Taker fee, bps | Core constructor, `takerFeeBps_` | Immutable Core instance | New deployment |
| Maker rebate, bps | Core constructor, `makerRebateBps_` | Immutable Core instance | New deployment |
| Maintenance margin, bps | `LiquidationModule` → `LiquidationPolicy` constructor | Set at deployment | New module/policy deployment; verify wiring constraints |
| Liquidation reward, bps | `LiquidationModule.configureLiquidatorReward` | Governed module configuration | Module owner, subject to code-level checks |
| Collateral units per lot-tick | `Core.configureAccountingUnitScale` | One-time configuration | Core owner before lock |
| Core advanced module | `Core.configureAdvancedModule` | One-time configuration | Core owner |
| Portfolio coordinator | `Core.configurePortfolioController` | One-time and only before local custody / insurance funds | Core owner |
| Funding updater | `Core.setFundingUpdater` | Mutable | Core owner |
| Signed funding index | `Core.setFundingIndex` | Mutable | Assigned funding updater |
| New risk paused | `Core.setRiskIncreasePaused` | Mutable | Core owner; updater may only set true |
| Core owner | `Core.transferOwnership` | Mutable | Current owner |
| Protocol fees to insurance | `Core.allocateProtocolFeesToInsurance` | Mutable allocation | Core owner |

**Do not describe immutable constructor settings as adjustable governance parameters.** A fee or margin change can require a replacement deployment and position/claim migration plan. Do not assume a module replacement is possible when Core wiring is set once.

## Validations and relationships

- Core constructor rejects a zero oracle or collateral address, zero initial margin, initial margin above 10,000 bps, taker fee above 10,000 bps, or maker rebate above taker fee.
- The deployment script performs additional validation. Read `DeployStandalone._validateConfig` and the versioned JSON deployment schema before changing inputs.
- Liquidation maintenance is a different policy from Core initial margin. Select values with a documented safety gap.
- Accounting scale is fixed after its one-time configuration. Verify token decimals and the meaning of one lot-tick before funding accounts.
- The book represents ticks with `uint16`: from 0 to 65,535. This is **not** an arbitrary token decimal precision control.
- The reference Core has no generic per-market `setTickSize`, `setLotSize`, `setOracle`, `setInitialMarginBps`, or `setTakerFeeBps` admin method.
- The optional `BoundedFundingUpdater` uses immutable operator, update interval and maximum index step. It tracks its own index and **cannot detect** a Core-owner funding authority rotation.

## Change procedure

1. Read the deployed contract addresses from the verified manifest.
2. Locate the actual owner and required signer for the specific setter.
3. Propose the change with exact old/new values, units and expected risk effect.
4. Simulate the transaction against the current deployment on a fork.
5. Approve it with the team's governance procedure. Use delayed approval for ordinary changes and a separate emergency policy for risk-off actions.
6. Submit and verify emitted events or storage getters on-chain.
7. Update the market manifest, configuration registry, monitoring thresholds and audit trail where applicable.
8. Reconcile maker inventory, outstanding orders and account margin before accepting more risk.

If a setting is immutable, use a controlled migration instead of suggesting a setter that does not exist. See [Governance and Keys](/docs/GOVERNANCE_AND_KEYS) and [Market Listing](/docs/MARKET_LISTING).

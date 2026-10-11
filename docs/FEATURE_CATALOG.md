# System Feature Catalog

This catalog describes the deployment integration surfaces in this repository. A listed feature is implemented code, not a guarantee that an exchange deployment is ready for unrestricted deployment funds. The integration team must test its own market parameters, oracle and operator configuration.

## 1. System matching and market state

| Feature | System behavior | Source |
| --- | --- | --- |
| Fully on-chain CLOB | Contracts store authoritative bids, asks and executable liquidity | `src/deployable/OrderBookCore.sol` |
| Price priority | Matching uses the best executable tick first | `OrderBookCore` |
| Pro-rata fills | At one price tick, makers hold proportional pool shares | `OrderBookCore` |
| 65,536 ticks | Two-level occupancy bitmap finds active prices | `OrderBookCore` |
| Maker lazy settlement | A maker materializes fills when it settles or changes its quote; the taker path does not loop through makers | `OrderBookCore` |
| Generation rollover | Filled pools advance generation; old maker claims settle against stored generation data | `OrderBookCore` |
| IOC and FOK | A taker can execute immediately or require a complete fill | `IOrderBookCore`, `OrderBookCore` |
| Reduce-only and minimum-fill | Risk-reducing order constraints and minimum-fill execution | `OrderBookCore`, advanced integration |

**System concern:** A pro-rata maker must reconcile its on-chain share claims, pending fills and funding across pool generations. The indexer is not an authority for custody.

## 2. System advanced order features

| Category | System features | Component |
| --- | --- | --- |
| Conditional execution | Stop and take-profit triggers; market-like and triggered-limit activation | `AdvancedOrderModule` |
| Linked instructions | OCO, OTO and bracket TP/SL composition | `AdvancedOrderModule` |
| Trailing orders | On-chain extrema-based trailing triggers | `AdvancedOrderModule`, extrema oracle |
| Time controls | Good-till-date expiry and permissionless cleanup | `AdvancedOrderModule` |
| Execution strategies | Iceberg replenishment, scheduled/TWAP slices and mark-pegged quotes | `ExecutionStrategyModule` |
| Order safety | Post-only admission, reduce-only constraints and module share locks | Core, Advanced, Strategy |

**System concern:** Trigger conditions do not submit transactions by themselves. A deployment keeper must detect eligible work and submit it. During congestion, trigger execution can be late or fail.

## 3. System market making

- `MarketMakerModule` supports batch quote refresh with typed and packed inputs.
- Maker quotes use on-chain pool shares and lazy fills.
- Maker software must track inventory, risk envelopes, accepted quote generations and transaction failures.
- Each deployment exchange provides its own maker strategies, private keys, RPCs and uptime targets. The repository does not provide committed liquidity.

## 4. System risk, collateral and funding

| Area | Implemented behavior | System operator action |
| --- | --- | --- |
| Standalone collateral | ERC-20 deposits and guarded withdrawals | Select and assess the token; reconcile custody |
| Margin | Initial exposure reservation and marked account equity | Set conservative limits and test gaps |
| Funding | Global signed funding index and lazy account settlement | Define calculation, cadence, authority and stale-data policy |
| Bounded funding wrapper | Optional operator cadence and per-update signed delta limits | Install before the first update; monitor governance changes |
| Liquidation | Maintenance checks and reduce-only closeouts against executable book liquidity | Run liquidators, keep order inventories complete |
| Insurance | Fund reserves; cover bounded terminal bad debt | Set reserve policy and monitor coverage |
| Portfolio margin | Shared collateral vault, coordinator and hedge-credit policy | Approve separately after cross-market validation |
| Fee accounting | Taker fee and maker rebate ledgers, protocol fee allocation to insurance | Review treasury policy and distribution limitations |

The deployment bounded funding wrapper cannot detect funding-index updates that the Core owner publishes through a different temporary updater. Refer to `docs/BOUNDED_FUNDING_UPDATER.md`.

## 5. System oracle and pricing integration

- Mark oracle interface with execution bands and freshness controls in the selected adapter.
- Extrema history interface for trailing-order execution.
- Optional reference oracle adapters, including single-source configuration.
- Your deployment oracle policy must specify stale data, feed outages, decimals, mark manipulation and chain sequencer interruptions where applicable.

Multiple oracle providers are **not** an unconditional protocol requirement.

## 6. System integration and operations

| Layer | Repo asset | Team responsibility |
| --- | --- | --- |
| Deployment | Foundry scripts; versioned spec and manifest schemas | Sign and broadcast; record actual addresses |
| SDK | Typed transaction plans, route selection and deployment verification | RPC integration, simulate, sign and submit |
| Bytecode attestation | Compare deployed runtime code with reviewed artifact bytes | Provide complete expected module address inventory |
| Indexer | Canonical replay and event-derived state | Durable database, independent reconciliation |
| Operator | Keeper plans, bounded catch-up, supervision and recovery primitives | 24/7 service, idempotent dispatch, monitoring |
| Frontend/API | Typed integration surfaces | Implement and host public user-facing services |
| Testing | Foundry fuzz, gas budget and mainnet WETH fork scenarios | Run testnet stress, deployment audits and incident drills |

## 7. System assurance status

The repository includes reproducible tests and deployable operational guidance. A team's deployment release still requires an independent contract audit, resolved findings, tested real-world oracle/funding controls, market maker and liquidation capacity, incident drills, custody reconciliation and legal/compliance review as applicable. Do not describe these external approvals as already complete.

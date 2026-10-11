# Perpetual DEX Integration Guide: From Fork to First Maker Quotes

> **Production documentation:** See [production feature catalog](PRODUCTION_FEATURE_CATALOG.md), [production system architecture](PRODUCTION_SYSTEM_ARCHITECTURE.md), and [production team handbook](PRODUCTION_TEAM_HANDBOOK.md). These explain production interfaces, team duties and release checks. An external audit and a deployment-specific production approval are still required before unrestricted customer funds.

This is an **operator-owned deployment guide**, not a hosted turnkey DEX and not a claim of independent security certification. Use it alongside [SELF_HOSTED_DEPLOYMENT.md](SELF_HOSTED_DEPLOYMENT.md), [OPERATOR_RUNBOOK.md](OPERATOR_RUNBOOK.md), and [INTEGRATION_OPERATOR_AUDIT.md](INTEGRATION_OPERATOR_AUDIT.md). All contract addresses, token decimals, oracle implementations, funding policies, and admin keys belong to the integrating team.

## 1. Integration model

| Layer | What this repo supplies | Integrator responsibilities |
| --- | --- | --- |
| On-chain execution | `OrderBookCore`, maker shares, price priority/pro-rata, IOC/FOK, settled positions | Chain selection, market parameters, collateral token, security review |
| Advanced orders | `AdvancedOrderModule`, `ExecutionStrategyModule`, stops, brackets, OCO/OTO, GTD, iceberg, scheduled/TWAP and pegged instructions | Trigger/expiry/slice keepers, emergency stop policies |
| Maker infrastructure | `MarketMakerModule` typed/packed quote batch execution | Inventory/risk strategies, maker signing, sufficient funds, refresh/latency objectives |
| Risk and liquidation | Maintenance check, bounded reduce-only liquidation, reserve accounting | Liquidation bots, executable opposing liquidity, insurance funding policy |
| Indexer/API | Reference event decoder, indexer, replay/checkpoint, operator read model | Reliable RPC/database, canonical-state reconciliation, frontend API |
| Operator | Supervised replay and guarded keeper dispatch | Durable idempotency, RPC redundancy, observability, signers and uptime |
| Oracles | Compatible mark interface and optional reference feed adapters | **Choose one provider or multiple**, verify source precision/staleness/sequencer policy, and supply `IExtremaOracle` history for trailing orders |

Do not install a cross-source oracle unless the deployment itself calls for one. The single-source path is supported.

## 2. Bootstrap one isolated market first

1. Clone the repository and pin a reviewed release commit, Solidity compiler `0.8.24`, Foundry and Node versions.
2. Install the dependencies actually declared by the repository. Run `forge test -vvv`, `forge test --gas-report`, and the SDK/indexer/operator package test commands from their respective package directories.
3. Create a declarative spec using `deployments/spec/schema/v1.json`. The sample at `deployments/spec/example.json` contains non-production addresses; **do not reuse them**.
4. Choose a vetted ERC-20, desired market symbol, matching chain, compatible mark oracle **with the extrema history interface required by `AdvancedOrderModule` when trailing orders are enabled**, funding updater, governance Safe/timelock, execution band, initial/maintenance margins, tick/lot accounting scale, fee schedule and liquidator incentive.
5. Run the SDK `validateDeploymentSpec` and `compileDeploymentEnvironments` functions; apply the output to the Foundry broadcast environment. The exact standalone fields are in [SELF_HOSTED_DEPLOYMENT.md](SELF_HOSTED_DEPLOYMENT.md).
6. Simulate, inspect, then broadcast:

```bash
forge test -vvv
forge script script/DeployStandalone.s.sol:DeployStandalone --rpc-url "$RPC_URL" -vvvv
# Broadcast only after the simulation and all addresses/risks have been approved
forge script script/DeployStandalone.s.sol:DeployStandalone --rpc-url "$RPC_URL" --broadcast -vvvv
```

7. Collect actual deployed addresses and the deployment block. Use the SDK `buildDeploymentManifest` to generate `deployments/schema/v1.json`-compatible output. Run `verifyDeploymentOrThrow` / `executeDeploymentVerification` against the intended chain; **fail closed** on missing code, ownership, oracle, scale, margin, module or chain mismatches. **The SDK only verifies bytecode presence, not code identity.** Independently compare each deployed contract's runtime bytecode hash (including linked-library/immutable normalization as appropriate) with the reviewed, reproducible compiler artifact before any production sign-off.
8. Record admin/funding powers. Never leave privileged production ownership on a throwaway broadcaster key.

For cross-market shared collateral use `DeployPortfolio` only after isolated-mode validation. Portfolio admission and liquidation introduce additional operational dependencies.

## 3. Required maker integration

Each maker must verify market addresses and the current mark before funding. In **standalone mode**, approve the collateral ERC-20 spender at `OrderBookCore` and deposit through Core. In **portfolio mode**, approve `PortfolioCollateralVault` as spender and deposit through the vault or SDK portfolio deposit route; Core direct deposits revert once portfolio mode is enabled. Use the SDK's canonical packed quote encoding or typed `MarketMakerModule.batchReplaceQuotes` transaction plans. Batches must be **strictly ordered by side and tick with no duplicates**. `batchReplaceQuotesPacked` uses one 16-byte record per quote: 96-bit quantity, 16-bit tick, one side bit, and zero reserved bits.

A maker should **not** infer its executed inventory solely from deposited shares, order placement events or off-chain target quotes. Fills are **lazy**: read the Core / IntegrationLens and the appropriate generation; settle or reconcile on-chain before making withdrawal or liquidation assumptions.

Market maker acceptance scenarios:

- Two makers at one tick, same price and pro-rata share distribution; fill/settle in either order.
- Cancel/replace after a partial taker fill; do not duplicate outstanding lots.
- Complete tick exhaustion, generation rollover, and subsequent quotes at the same tick.
- Mass batch refresh with an insufficient margin budget must revert atomically.
- Maker process restart with stale local quote targets: rebuild from canonical events plus Core/Lens reads, not a remembered local order map.
- Oracle stale/unavailable or emergency risk-off: stop submitting new risk and preserve cancellation paths.
- Limit transaction size and track gas at the intended maker quote depth; EVM matching gas scales with *crossed ticks*, not number of makers.

## 4. Operator startup and failure protocol

Use the repo's reference indexer, manifest-bound checkpoints and operator tools, or a compatible independently implemented backend. Publication is only safe after verified canonical replay. A production service must:

- Verify chain identity, bytecode, module wiring, oracle state and admin authorities on startup.
- Restore finalized canonical checkpoints matching deployment identity; replay from the deployment block if no valid checkpoint exists.
- Stop transaction submission and read readiness on mismatched canonical block hashes, failed persistence, unexpected chain ID or recovery errors.
- Attach deterministic keeper idempotency keys to submissions and persist **submission keys + transaction hashes** across worker restarts.
- Simulate transactions *immediately* before sending; indexer-triggered tasks are candidates, not guaranteed executable orders.
- Handle deep reorgs with an operator-approved checkpoint rebuild, not a guessed rollback.
- Run independent RPC quorum and alerting where the deployment's risk profile demands it.
- Verify live account risk before liquidating; historical portfolio lock events alone are insufficient.

SLO/alert targets are **integrator-defined**, not encoded in protocol: safe-head lag, oracle source age, funding updater delay, keeper expiry/trigger backlog, failed simulations, pending transactions, liquidation latency, available opposing book depth, insurance balance, and collateral custody.

## 5. End-to-end acceptance plan

Complete these against the actual target-chain contracts and collateral token, with a mainnet fork and testnet repeat:

1. **Custody:** deposit, verify ERC-20 balance delta, attempt over-withdraw, and withdraw only eligible settled cash.
2. **Trading:** maker quotes both sides, taker IOC/FOK, partial and multi-tick fill; settle lazy maker exposure; reconcile signed sum of positions to zero.
3. **Margin:** refuse new exposure on insufficient equity; attempt maker/taker risk increase during emergency pause; cancel risk while paused.
4. **Funding:** change global index while some makers remain unsettled; reconcile settled + pending funding across accounts, including rounding budget.
5. **Advanced orders:** stop/TP, triggered rest, OCO/OTO bracket and GTD cancellation, trailing expiry, multi-worker idempotency.
6. **Liquidation:** breach maintenance with adverse mark, no liquidity, partial liquidity, repeated liquidations, fully flat terminal bad debt, insurance exhausted, no repeated coverage after recovery.
7. **Operator failure:** delayed and duplicate logs, RPC outage, chain mismatch, disk failure, safe-head lag and restart across a short and deep reorg.
8. **Market-maker acceptance:** concurrent quote publishers, failed batch rollback, low-gas quote replacement, maker fills after process restart and generation rollover.
9. **Shutdown and recovery:** risk-off prevents new risk; withdrawals/cancellations allowed subject to margin rules; verify restart from finalized checkpoint.

A green unit test suite is necessary but does not prove liveness or market economics. Independent contract security review, risk-model stress, target-chain deployment verification, executable liquidity and incident rehearsal are mandatory before production fund admission.

## 6. Security and economic launch gates

**Do not launch unrestricted real-money trading until:**

- Independent security audits and remediation have been completed on the *deployed* build/configuration.
- Final deployed runtime bytecode hashes are compared with independently reviewed reproducible artifacts; separately verify authority handoffs, fee schedule and oracle freshness/scale on-chain.
- Liquidator profitability and market-maker depth have been tested against severe but plausible jumps.
- Insurance policy, known residual debt states, and deficit management are documented.
- Keeper/indexer failover, finality, persistence and RPC divergence are rehearsed.
- An incident commander has tested risk-off authority and rollback/recovery procedures.
- Deposit → quote → position → funding → close/liquidate → settlement → withdrawal passes with real target-chain token contracts.

## 7. Integration file map

- `script/DeployStandalone.s.sol` / `script/DeployPortfolio.s.sol`: contract deployment and role wiring
- `deployments/spec/schema/v1.json`: declarative integration source
- `deployments/schema/v1.json`: canonical manifest structure
- `sdk/README.md`: transaction planning and deployment verification
- `reference/indexer/README.md`: event replay and checkpoint recovery
- `operator/README.md`: keeper, liquidation and supervisor tooling
- `docs/OPERATOR_RUNBOOK.md`: failure and recovery procedures
- `test/MainnetFork.t.sol`: real mainnet WETH custody baseline

The reference integration is modular intentionally: a team can select its preferred RPC, signer, database, and single oracle without changing the fully on-chain matching architecture.


### Executable code-identity gate

In addition to the SDK's wiring and code-presence checks, call `attestRuntimeCodeOrThrow` with **every** protocol contract's deployment-specific, independently reviewed runtime artifact. Runtime bytecode must be the final linked code with constructor immutables resolved. The helper rejects a wrong chain, missing code, byte mismatch and RPC errors. Teams must independently review proxy implementation identities and any unlisted tokens/oracles. The helper does not generate reproducible artifacts or replace independent contract audits.

# Targeted adversarial security review — Ethereum WETH mainnet fork

**Scope:** `OrderBookCore`, `AdvancedOrderModule`, `LiquidationModule`/`LiquidationPolicy`, `BoundedFundingUpdater`; real Ethereum mainnet WETH custody via `vm.createSelectFork(ETH_RPC)`. This is a focused code review and executable regression suite, **not** comprehensive third-party audit certification or a claim that all attack surfaces are safe. Test contract: `test/AdversarialWethMainnetFork.t.sol`.

## Finding 1 — Privileged funding authority rotation bypasses wrapper limits

**Severity: Medium / trusted-governance threat model, confirmed by source; fork test added.** `BoundedFundingUpdater` compares proposed updates against its own `lastIndexX18`, not the Core's actual funding index (which is private). Core ownership can rotate `fundingUpdater`, publish an arbitrary signed index, then reassign the bounded wrapper. That wrapper does not notice the interim mutation. This does not give a non-privileged user a new capability; it means the wrapper protects against *operator mistakes under uninterrupted assignment*, not governance compromise or malicious governance.

**Hardening:** require an audited governance/timelock policy for funding updater rotation, monitor `FundingUpdaterChanged` and `FundingIndexUpdated`, and halt trading/require incident review when the active updater differs from the approved wrapper. A truly protocol-enforced bound requires Core-level enforcement or a verified index view and tighter ownership assumptions; previous exploratory getter additions exceeded the repo's 22,000-byte Core size gate, so this PR does not weaken the bytecode limit.

## Finding 2 — Liquidation depends on complete open-order cleanup

**Severity: Medium / liveness and operations; expected fail-closed behavior.** `LiquidationPolicy.hasOpenOrders` returns true for outstanding maker quotes or advanced/strategy orders, so distressed accounts cannot liquidate until those orders are force-cancelled. `LiquidationModule.liquidate` accepts caller-supplied quote ticks and order IDs to perform cleanup. When the order locator/indexer omits a quote, the transaction can revert without closing exposure. The fail-closed check prevents liquidation while untracked risk remains, but it creates an indexer/keeper operational dependency. Once cleaned, an empty opposing book still yields zero forced closeout: no imaginary fills or new custody.

**Hardening:** resilient canonical order-key replay, duplicate independent indexer paths, gas-bounded batched cleanup, and metrics on distressed accounts awaiting quote/strategy cleanup. Measure worst-case keeper progress under RPC downtime and chain reorgs. Do not claim a liquidator can forcibly close when opposing liquidity is absent.

## Finding 3 — Cross-account collateral withdrawal

**Severity: Informational / negative-path confirmation.** The stand-alone core withdraws only against the caller's settled cash claims. An unfunded EOA calling `withdrawCollateral(1)` must fail without reducing custody of actual WETH deposited by another user.

## Follow-up audit scope

This suite does **not** establish multi-asset solvency, all reachable pro-rata generation states, operator incentive sufficiency, atomic cross-market bankruptcy safety, MEV resistance, governance key security, oracle manipulation resistance, or availability of deep liquidation liquidity. Before real funds: independent specialized security audit and remediation, deployment-specific funding formula and governance review, longer-run invariant fuzzing, and a continuously operated multi-maker testnet pilot.

**Execution:** `ETH_RPC=<Ethereum mainnet RPC URL> forge test --match-contract AdversarialWethMainnetForkTest -vvv` or the repository's Ethereum mainnet fork CI job. A test proving expected existing behavior is not evidence of an exploitable smart-contract vulnerability.

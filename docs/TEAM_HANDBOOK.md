# System DEX Team Handbook

This handbook explains how a team can prepare and run its **own deployment EVM perpetual DEX** with this repository. The repository supplies the contracts and reference integration primitives. The team supplies keys, liquidity, funding and oracle policy, infrastructure, compliance decisions and an independently approved deployment release.

> **System integration diagrams:** See [deployment integration flows](/docs/INTEGRATION_FLOWS) for frontend, SDK, indexer, keeper, market-maker, liquidation, deployment-mode and incident-response diagrams.

> **Integration guides:** [List a market](/docs/MARKET_LISTING) · [Parameter reference](/docs/PARAMETER_REFERENCE) · [Governance and keys](/docs/GOVERNANCE_AND_KEYS).

## 1. Assign deployment owners

| System role | Required duty | Evidence before launch |
| --- | --- | --- |
| Protocol lead | Own parameters, release commit and contract manifest | Approved deployment specification |
| Security lead | Arrange external audit, triage findings and control access | Signed remediation and release review |
| Deployment engineer | Broadcast and verify contracts | Chain-specific deployment records and runtime-code attestation |
| Risk lead | Define leverage, fees, funding, oracle and insurance policy | Stress report and incident thresholds |
| Market-maker lead | Qualify makers and inventory risk | Quoting, fills and reconciliation logs |
| Operator lead | Run indexer, keepers and liquidators | Recovery drills, alert rules and uptime targets |
| Treasury / governance lead | Secure Safe/timelock and emergency keys | Access matrix and rotation procedure |

Do not make one unreviewed private key the sole control for all deployment roles.

## 2. Prepare the deployment environment

1. Pin the repository commit, Foundry compiler configuration and Node dependencies.
2. Review [deployment feature catalog](/docs/FEATURE_CATALOG) and [deployment architecture](/docs/SYSTEM_ARCHITECTURE).
3. Select collateral token, market parameters, mark oracle, extrema history and funding calculation. A single trusted oracle provider is permitted if your risk approval accepts it.
4. Allocate a deployment admin Safe/timelock, funding operator, keeper transaction accounts and independent monitoring.
5. Set an executable liquidity policy with participating market makers and a liquidation reserve plan.
6. Record supported chain, RPC finality assumptions, block gas constraints and sequencer policy where relevant.

## 3. Validate the deployment repository

From the repository root:

```sh
forge test -vvv
forge test --gas-report
forge snapshot
ETH_RPC=https://YOUR_MAINNET_RPC forge test --match-contract PerpLifecycleWethMainnetForkTest -vvv
ETH_RPC=https://YOUR_MAINNET_RPC forge test --match-contract AdversarialWethMainnetForkTest -vvv
```

The `ETH_RPC` value must be a real, trusted Ethereum mainnet RPC endpoint. The fork tests operate on a forked local state; they do not deploy your protocol to Ethereum mainnet or a public testnet.

Run package tests according to the package scripts in `sdk/package.json` and `operator/package.json`. Ensure every required GitHub Actions gate is green on the exact release commit.

## 4. Build and deploy a deployment market

1. Start with one standalone market. Do not enable portfolio margin during the first acceptance cycle.
2. Copy the *structure* of `deployments/spec/example.json`, not its non-deployment addresses.
3. Validate the spec with `validateDeploymentSpec`.
4. Use `compileDeploymentEnvironments` to produce the inputs expected by `script/DeployStandalone.s.sol`. Review chain IDs, collateral accounting scale, oracle address, fee schedule, margin and liquidation settings.
5. Dry-run Foundry deployment and review gas, ownership and initialization outcomes.
6. Broadcast to a team-managed testnet first. Record actual addresses and deployment block.
7. Build the canonical manifest with `buildDeploymentManifest`; verify addresses, admin, updater and all market wiring with `verifyDeploymentOrThrow`.
8. Compare each required deployed runtime bytecode against the reviewed build with `attestRuntimeCodeOrThrow`. The caller must provide a **complete** expected address set; the helper does not discover omitted contracts.
9. Publish the reviewed manifest and store its digest with operator checkpoints. Repeat the procedure for a later approved deployment chain release.

See [self-hosted deployment](/docs/SELF_HOSTED_DEPLOYMENT) for full Foundry environment variables, scripts, schemas and authority handoff.

## 5. Bring up the deployment operator

1. Implement RPC, decoded event transport, durable checkpoint store, simulation and transaction submission.
2. Configure confirmation depth and bounded block catch-up.
3. Replay from the manifest deployment block; compare state with direct Core reads.
4. Qualify reorg rollback and replay before enabling deployment keeper transactions.
5. Verify that the operator can discover every maker quote, advanced order and strategy order needed for liquidation cleanup.
6. Put transaction simulation before signing. Use durable nonce tracking and idempotent task keys.
7. Run a controlled outage and restart drill. Record recovery time and missed-action counts.

The reference operator is a **library**, not a deployment hosted keeper service. See [operator runbook](/docs/OPERATOR_RUNBOOK).

## 6. Qualify deployment market makers

- Test quote placement, packed and typed quote updates, cancellations and settlements.
- Test pro-rata partial fills with multiple makers at one price.
- Reconcile the maker's inventory, position, funding and collateral after a restart.
- Measure quote gas cost, reject rate and maximum cancel latency during market shocks.
- Confirm a deployment fallback maker or liquidation liquidity source.
- Do not infer available exit liquidity from posted but stale or non-executable quotes.

## 7. Approve deployment risk controls

| System gate | Required proof |
| --- | --- |
| Collateral custody | Balance reconciliation across deposits, fills, funding, fees, withdrawals and bad debt |
| Funding | Documented formula, per-update limits, missed-update rules and governance rotation monitoring |
| Liquidation | Zero-liquidity, partial-close, cancellation, insurance exhaustion and keeper gas scenarios |
| Oracle | Correct decimals, execution bands, freshness, source outages and emergency plan |
| Governance | Admin ownership, key rotations, timelocks and incident response rehearsal |
| Portfolio | Independent cross-market risk and custody validation before enabling |
| Security | Completed external audit, remediation review and approved deployment risk acceptance |

**Release policy:** Do not describe a staging environment as independently approved for deployment funds. The repository cannot certify a team's parameter choices, collateral, market makers or deployment authorities.

## 8. Run and recover a deployment exchange

- Track canonical chain head, reorg depth, indexer lag, pending keeper work and failed simulation count.
- Track oracle age, funding cadence, current insurance reserves, under-maintenance accounts and unfilled liquidation residuals.
- Alert when the Core funding updater changes or the bounded wrapper is no longer the approved active authority.
- During outage, stop unsafe risk-increasing actions according to the team incident plan; maintain the owner-only process for unpause.
- After recovery, reconcile canonical logs, direct Core state, vault/token balances and maker inventory before resuming deployment automation.
- Store postmortems and changes to thresholds in deployment release records.

## 9. Expand after the deployment pilot

Scale markets, maker capacity and operator replicas only after the first market passes a sustained testnet pilot. Enable portfolio margin in a separate release with its own security and economic tests. Treat any new collateral, oracle, or chain as a new deployment risk boundary.

## Additional deployment references

[Integration guide](/docs/PERP_DEX_INTEGRATION_GUIDE) · [Operator runbook](/docs/OPERATOR_RUNBOOK) · [Architecture](/docs/SYSTEM_ARCHITECTURE) · [Feature catalog](/docs/FEATURE_CATALOG) · [Bounded funding](/docs/BOUNDED_FUNDING_UPDATER) · [Mainnet fork review](https://github.com/en0ma/order-book/pull/130)

# Operator trading-safety boundary

The `operator/trading-safety` API denies risky operations on stale, future, deviating or sequencer-down prices and provides a manual risk-off gate. Cancellation and settlement remain admitted. It is an **off-chain preflight**, not an on-chain guardian or atomic guarantee. Deployments must simulate the transaction, check the mark again at submission and implement contract-side emergency control before using real funds.

## On-chain risk-off authority

Core's existing `fundingUpdater` may activate `setRiskIncreasePaused(true)`; only `owner` may disable it. This deliberately reuses the funding operator to avoid expanding near-budget Core runtime bytecode, **and expands that operator's authority to halt new trading**. Use a secured dedicated funding operator if appropriate. There is no separate guardian address or rotation mechanism; `setFundingUpdater` controls both funding and emergency-pause delegation. Incident responders must explicitly review that coupling and owner recovery. Normal cancellation and settlement remain available during risk-off.

The pause state is exposed by the on-chain `riskIncreasePaused()` getter. To meet Core's strict runtime bytecode budget, the pause setter does **not** emit a dedicated event; monitors must poll or query canonical state after incidents and reorgs.

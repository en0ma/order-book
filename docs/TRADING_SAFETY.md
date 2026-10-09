# Operator trading-safety boundary

The `operator/trading-safety` API denies risky operations on stale, future, deviating or sequencer-down prices and provides a manual risk-off gate. Cancellation and settlement remain admitted. It is an **off-chain preflight**, not an on-chain guardian or atomic guarantee. Deployments must simulate the transaction, check the mark again at submission and implement contract-side emergency control before using real funds.

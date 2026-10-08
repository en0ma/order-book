# Canonical readiness and recovery boundary

The `/readiness` module evaluates an operator's index snapshot and diagnostics against a deployment-configured lag policy. It refuses absent canonical heads, stale/mismatched diagnostics, stalled indexers, and excessive safe-head lag. This is a **pure admission check** for serving cached public data, not an oracle for the safety or finality of a block.

Set `createHttpRuntime({ readiness: { requireDiagnostics: true, maxLagBlocks: 0 }, ... })` to gate all data routes until the local index is caught up to its safe head. `GET /ready` always returns the computed readiness result with HTTP 200 or 503 and the canonical head hash. Default HTTP routing preserves existing deployments: configure `readiness` explicitly to enable fail-closed gating. For deployment operators, the recommended setting is `requireDiagnostics: true` with `maxLagBlocks: 0`.

Recover by verifying RPC chain identity, rolling back orphaned blocks to the known canonical ancestor, replaying canonical logs, atomically persisting matched index and strategy snapshots, and only then promoting a new read model. During deep reorg or unavailable RPC, expose 503 rather than stale data. Never derive confirmed settlement or withdrawable collateral from an indexed tick pool.

The self-hosted team remains responsible for running the indexer and keeper, RPC/network configuration, TLS, authorization, resource limits, persistent checkpoints, and audit/reconciliation. None of these controls changes matching logic or Core bytecode.

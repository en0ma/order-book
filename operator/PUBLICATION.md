# Recovery publication and keeper safety

`createRecoveryPublication(manifest, rpc, store, options)` connects canonical recovery, persistence, read publication, and keeper admission. The caller supplies a trusted RPC adapter and an atomic recovery store. This library does not run a database, HTTP server, wallet, or keeper signer.

## Sequence

1. Construct the controller; `ready()` is false and `snapshot()` rejects.
2. Call `refresh()`. It validates chain identity and saved canonical checkpoint, replays the Core index and strategy registry, checks the canonical hash, then awaits atomic persistence.
3. After a **ready** refresh commits, `snapshot()` returns the full canonical read model. Connect it as the `snapshot` callback in `createHttpRuntime` and set `readiness: { requireDiagnostics: true, maxLagBlocks: 0 }`.
4. A lagging refresh leaves reads closed. A failed RPC, reorg, or persistence attempt also closes reads, even when a previously good model exists. An operator must call `refresh()` again.
5. Use `submit(tasks, executor, verifier)` for Core keeper tasks. The method requires a ready committed bundle and invokes `executeReadyTasks`, which checks canonical head hashes and simulates tasks before submission.

Concurrent refresh and submit calls are serialized. A refresh immediately closes the publication gate while queued; no stale model is served during replay.

## Safety limitations

The controller does not verify finality after commit, implement deep-reorg rollback, sign transactions, reconcile live strategy observations, or authenticate HTTP requests. RPC reorgs after the final hash check remain possible. Use a trusted verifier and recheck on-chain state in the signing adapter. The operator must supply atomic persistence, authentication, TLS, and deployment monitoring. If a checkpoint is orphaned, rebuild from a trusted canonical checkpoint before resuming. This is a reference boundary, not an audited production service.

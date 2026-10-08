# Continuous canonical operator supervision

Use `createSelfHostedOperator(...).supervise()` to run recurring canonical recovery with bounded retry delay and fail-closed keeper admission. The existing atomic disk store, combined Core/strategy replay, HTTP readiness, and JSONL recovery journal remain in use.

```js
const operator = createSelfHostedOperator(manifest, rpcAdapter, {
  bundlePath: "./private/recovery.json",
  auditPath: "./private/recovery-audit.jsonl",
  http: { authorizeAccount },
});
await operator.bootstrap({ maxCycles: 100, listen: { port: 8080 } });
const controller = new AbortController();
const supervisor = operator.supervise({
  intervalMs: 1000,
  maxBackoffMs: 30000,
  signal: controller.signal,
  onCycle: event => console.log(event.kind, event.head ?? event.message),
});
const supervision = supervisor.run();
// Only pass Core keeper tasks, a trusted canonical verifier, and a signing adapter.
await supervisor.submit(tasks, executor, verifier);
// On shutdown: stop first, then wait for the active replay before closing HTTP.
supervisor.stop();
await supervision;
await operator.http.close();
```

The first supervised pass revalidates the canonical chain, even after successful startup. The supervisor blocks keeper submissions until the first ready pass. A lagging or failed pass closes read publication and pauses keeper admission. Retries use exponential delay up to `maxBackoffMs`; successful or lagging passes use `intervalMs`. An abort signal or `stop()` halts the loop after an in-flight recovery. The supervisor itself does not hold wallet keys or submit transactions without the caller's explicit `submit()`.

**Limits:** This is a single-process reference controller, not a hosted service. It does not make an orphaned checkpoint canonical, guarantee finality after a hash check, automatically rebuild deep reorgs, perform strategy live-state reconciliation, or autonomously schedule/submit keeper tasks. An operator must provide monitoring, trusted RPC, deployment-specific authorization, replay recovery policy, durable signer idempotency, and disaster recovery. The protocol is not audited or production-ready.

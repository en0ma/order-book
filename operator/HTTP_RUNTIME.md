# Runnable self-hosted HTTP boundary

The `@en0ma/order-book-operator/http` export is an optional, dependency-free Node.js HTTP adapter over the read model. It does not start itself. Adopting DEX teams provide an atomically captured, finalized canonical `ReadModel` from their own indexer/checkpoint and call `listen(port, host)` explicitly. The default listen address is loopback `127.0.0.1`, not a public address.

## Example

```ts
import { createHttpRuntime } from "@en0ma/order-book-operator/http";

const app = createHttpRuntime({
  markets: ["ETH-PERP"],
  snapshot: async () => getAtomicallyCapturedCanonicalReadModel(),
  authorizeAccount: async (request, address) =>
    await authenticateReadAccess(request.headers.authorization, address),
});
await app.listen(8080); // Binds loopback by default; terminate TLS at your own proxy.
```

These application functions are intentionally user-supplied, not bundled infrastructure.

## Operational trust boundaries

- Public aggregate book and market views are read-only. Private account paths return 403 unless a caller-supplied authorization hook permits them. Never consider a caller-provided account address proof of ownership.
- Authentication and snapshot provider awaits are bounded by `requestTimeoutMs` with an application-level deadline; the HTTP handler returns 503 for stalled providers. Timeout does not cancel external RPC work: providers should implement their own abortable calls and resource limits.
- Duplicate, unknown, or oversized query parameters fail closed. Only GET/HEAD are allowed. The runtime limits path/query size and request/header lifetime, and returns `no-store` and `nosniff` response headers.
- `maxConcurrentRequests` limits in-flight application handlers (default 64). Excess requests return 503 rather than accumulating unbounded RPC work. Slots are reclaimed after both normal responses and premature client disconnects.
- `metrics()` reports active, total, rejected and handler errors, while `onRequest` receives status/duration and a route with account addresses redacted. The callback is best-effort and must not influence requests; do not include credentials in application logs.
- `close()` stops new request acceptance, marks the server as draining and closes idle connections. Upstream provider operations must implement their own timeout/abort behavior. 
- Requests require a canonical head, and each response returns `x-canonical-head`. A missing head or failed snapshot provider returns 503.
- Pagination is bound to chain ID, head hash/number and scope by the read-model package. Clients must restart pagination after a reorg or head advance.
- Operators must independently implement RPC trust, persistence, reorg rollback, request rate limiting, robust authentication, TLS, DDoS protection, access logs without credential leakage, and graceful shutdown. This reference HTTP adapter is not a substitute for production edge infrastructure.
- Strategy placement metadata and pool levels do not constitute settled maker positions, full account balances, or executable trades. All write actions must be simulated against current authoritative contracts.

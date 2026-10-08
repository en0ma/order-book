# Self-hosted API and read-model adapter

This package exposes a dependency-free pure read layer under `@en0ma/order-book-operator/read-model`. It consumes the canonical operator's JSON-safe `ApiSnapshot` plus the strategy registry snapshot and optional diagnostics. It does **not** operate a hosted service.

## Routes (transport-neutral)

`routeRead(model, method, pathname, query, knownMarkets)` returns status and JSON-safe body:

- `GET /health`: catch-up diagnostics; stalled indexers return HTTP 503 when diagnostics are supplied
- `GET /markets`: configured market IDs
- `GET /markets/:id/book?depth=25`: nonzero aggregate price levels, bid prices descending and ask prices ascending, each side capped to 100 levels
- `GET /accounts/:address?limit=50&cursor=...`: strategy placement registry and indexed portfolio lock, with bounded cursor pagination
- `GET /strategies?marketId=ETH-PERP&limit=50&cursor=...`: strategy placement registry, with bounded cursor pagination

All responses are JSON-safe and suitable for a team's own HTTP/WS adapter. Cursor pagination is stable only for a fixed canonical snapshot; include the `head` hash in client cache keys and invalidate on reorg. Never expose the pure handler directly to the public internet without the team's usual access control, rate limiting, and request/response limits.

## Correctness boundaries

Book pools are **aggregate, indexed tick levels**, not settled per-maker quotes or a promise of immediate trade execution. The authoritative Core can change between the snapshot and submission. Strategy registry records are placement/lifecycle metadata, **not** lazy maker-fill quantities or current execution progress. Fetch live `strategyStatus`/resting slice state before presenting precise strategy remaining lots and before scheduling keepers. The account surface deliberately does not invent balances, PnL, cash positions, liquidation decisions, or withdrawable collateral from incomplete indexed data.

Use the existing `ReferenceIndexer` checkpoint and confirmation policy for canonical state. If combining strategy snapshots with Core snapshots, capture them at the same canonical head, and use the same rollback marker on reorg. The caller remains responsible for persistence, RPC, signer, authentication, database, HTTP listener, and WebSocket delivery.

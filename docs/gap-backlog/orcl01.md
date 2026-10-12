# ORCL-01 — oracle asset identity and source attestation

**Status:** BACKLOG SPECIFICATION ONLY — no feature implementation or merge approval.

**Owner:** Shared

## Scope

Verify deployed source, asset pair, quote, decimals, heartbeat, market and Core oracle identity from a separately approved spec.

## Acceptance criteria

Wrong feed/network, stale/future/zero/deviating price and decimal mismatch reject; independence DEX-owned.

## Dependencies

#164 #167.

## Merge guard

Do not merge this specification-only draft. Implementation needs reviewed production code when applicable, adversarial tests, exact-head green CI and zero unresolved review threads. No DEX-owned price/rate policy embedded in reusable engine.

# ORCL-02 — oracle outage failover and restoration

**Status:** BACKLOG SPECIFICATION ONLY — no feature implementation or merge approval.

**Owner:** Shared

## Scope

Define fail-closed execution and risk-off transitions for stale sources, feed downtime and sequencer outages.

## Acceptance criteria

Test cancellations and reducing fills while blocked increases; authorized restoration only; DEX owns uptime.

## Dependencies

#166.

## Merge guard

Do not merge this specification-only draft. Implementation needs reviewed production code when applicable, adversarial tests, exact-head green CI and zero unresolved review threads. No DEX-owned price/rate policy embedded in reusable engine.

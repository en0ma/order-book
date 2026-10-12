# FUND-01 — transport-neutral funding publication integrity

**Status:** BACKLOG SPECIFICATION ONLY — not an implementation, passing test or release approval.

**Owner:** Shared

## Scope and implementation boundary

Ship deterministic signed-index publication preflight and catch-up/replay interface without choosing venue formula, rates or market data.

## Acceptance criteria before implementation PR can merge

Monotonic cadence, bounded delta, wrong-chain/stale/repeated indexing, gap reconciliation and disabled-operator cases verified; no rate formula hardcoded.

## Dependencies and existing evidence

BoundedFundingUpdater.

## Delivery gate

An implementation revision must include production code where protocol-owned, negative and adversarial tests, explicit ABI and custody implications, an up-to-date boundary register, all required CI jobs passing on its exact head commit, zero unresolved review threads and independent review where custody or economic solvency is implicated. Do not merge this specification-only draft as a feature.

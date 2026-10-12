# CUST-01 — standalone collateral and callback invariants

**Status:** BACKLOG SPECIFICATION ONLY — no feature implementation or merge approval.

**Owner:** Protocol

## Scope

Test ERC20 failure/reentrancy, refunds, insurance reserves and claims during negative equity.

## Acceptance criteria

No unsupported token credits, duplicate withdrawals or claims exceeding backing; fuzz callbacks and failure paths.

## Dependencies

Core custody tests.

## Merge guard

Do not merge this specification-only draft. Implementation needs reviewed production code when applicable, adversarial tests, exact-head green CI and zero unresolved review threads. No DEX-owned price/rate policy embedded in reusable engine.

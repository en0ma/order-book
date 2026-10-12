# FUND-02 — funding authority rotation and bypass detection

**Status:** BACKLOG SPECIFICATION ONLY — not an implementation, passing test or release approval.

**Owner:** Shared

## Scope and implementation boundary

Detect governance rotation away from bounded updater, index checkpoint divergence, unauthorized publisher and post-incident reinstatement.

## Acceptance criteria before implementation PR can merge

Regression on rotate-away-and-back and direct Core writes; alert and fail closed before relying on wrapper state; governance signer remains DEX-controlled.

## Dependencies and existing evidence

#166.

## Delivery gate

An implementation revision must include production code where protocol-owned, negative and adversarial tests, explicit ABI and custody implications, an up-to-date boundary register, all required CI jobs passing on its exact head commit, zero unresolved review threads and independent review where custody or economic solvency is implicated. Do not merge this specification-only draft as a feature.

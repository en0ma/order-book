# GOV-01 — emergency role permission matrix and recovery transitions

**Status:** BACKLOG SPECIFICATION ONLY — not an implementation, passing test or release approval.

**Owner:** Protocol + DEX operations

## Scope and implementation boundary

Audit pause behavior over Core, Advanced, liquidation, portfolio gateway, funding owner rotation and guardian wrapper.

## Acceptance criteria before implementation PR can merge

Separate risk-increasing from reducing actions; demonstrate cancellation, settlement, deposits and safe withdrawals remain accessible; only governance unpauses; stage recovery tests.

## Dependencies and existing evidence

#166.

## Delivery gate

An implementation revision must include production code where protocol-owned, negative and adversarial tests, explicit ABI and custody implications, an up-to-date boundary register, all required CI jobs passing on its exact head commit, zero unresolved review threads and independent review where custody or economic solvency is implicated. Do not merge this specification-only draft as a feature.

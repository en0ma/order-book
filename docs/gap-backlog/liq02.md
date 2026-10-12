# LIQ-02 — complete active-order inventory for liquidators

**Status:** BACKLOG SPECIFICATION ONLY — not an implementation, passing test or release approval.

**Owner:** Shared

## Scope and implementation boundary

Provide bounded, replay-safe completeness evidence for caller-supplied maker keys, advanced conditionals, trailing orders, strategy and managed quotes before liquidations.

## Acceptance criteria before implementation PR can merge

Test omissions, stale generations, reorg rollback, gas-bound batches and replay; never imply a missing ID means the order is absent.

## Dependencies and existing evidence

Operator read model and IntegrationLens.

## Delivery gate

An implementation revision must include production code where protocol-owned, negative and adversarial tests, explicit ABI and custody implications, an up-to-date boundary register, all required CI jobs passing on its exact head commit, zero unresolved review threads and independent review where custody or economic solvency is implicated. Do not merge this specification-only draft as a feature.

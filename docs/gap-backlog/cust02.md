# CUST-02 — stateful multi-market insolvency and conservation

**Status:** BACKLOG SPECIFICATION ONLY — not an implementation, passing test or release approval.

**Owner:** Protocol

## Scope and implementation boundary

Model cross-market positive/negative cash, unrealized PnL, pending funding, hedge credits, collateral vault and terminal bad debt across market transitions.

## Acceptance criteria before implementation PR can merge

Stateful fuzz/invariant suite asserts aggregate token backing; no phantom claim creation or fee/insurance double counting; explicit negative equity and recovery cases.

## Dependencies and existing evidence

#159 #160 #169 #170.

## Delivery gate

An implementation revision must include production code where protocol-owned, negative and adversarial tests, explicit ABI and custody implications, an up-to-date boundary register, all required CI jobs passing on its exact head commit, zero unresolved review threads and independent review where custody or economic solvency is implicated. Do not merge this specification-only draft as a feature.

# FEE-03 — on-chain distributable-fee solvency and payout boundary

**Status:** BACKLOG SPECIFICATION ONLY — not an implementation, passing test or release approval.

**Owner:** Protocol

## Scope and implementation boundary

Define a provable on-chain surplus calculation that preserves collateral claims, signed realized and pending funding cashflows, lazy rebates, insurance reserves and bad debt under both standalone and portfolio modes.

## Acceptance criteria before implementation PR can merge

No treasury token transfer until complete invariant and independently reviewed authorization/recipients; cover zero/partial payouts, reentrancy and abnormal ERC20s; verify no EIP-170/gas regression.

## Dependencies and existing evidence

#168 #169 #170.

## Delivery gate

An implementation revision must include production code where protocol-owned, negative and adversarial tests, explicit ABI and custody implications, an up-to-date boundary register, all required CI jobs passing on its exact head commit, zero unresolved review threads and independent review where custody or economic solvency is implicated. Do not merge this specification-only draft as a feature.

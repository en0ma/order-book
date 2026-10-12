# LIQ-01 — partial and zero-liquidity liquidation lifecycle

**Status:** BACKLOG SPECIFICATION ONLY — not an implementation, passing test or release approval.

**Owner:** Protocol + integration

## Scope and implementation boundary

Specify execution and settlement lifecycle for partial IOC fills, residual unhealthy positions, repeat attempts, terminal debt and paid liquidator rewards.

## Acceptance criteria before implementation PR can merge

Regression demonstrates zero fill never closes a position or pays phantom reward; cover partial fills, stale price, bad debt, cleanup failure and insurance limits.

## Dependencies and existing evidence

Existing LiquidationModule and PortfolioLiquidationModule.

## Delivery gate

An implementation revision must include production code where protocol-owned, negative and adversarial tests, explicit ABI and custody implications, an up-to-date boundary register, all required CI jobs passing on its exact head commit, zero unresolved review threads and independent review where custody or economic solvency is implicated. Do not merge this specification-only draft as a feature.

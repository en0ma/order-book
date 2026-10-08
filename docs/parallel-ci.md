# Parallel CI validation

The pull-request workflow runs all existing checks. It uses separate jobs to reduce wall-clock time, not to reduce test coverage.

## What runs

| Job | Procedures |
| --- | --- |
| node | SDK tests, reference indexer tests, operator tests |
| protocol | Foundry formatting, unit tests, fuzz tests, and gas ceiling tests |
| fork | Ethereum mainnet fork tests using the configured RPC, with the existing public fallback |
| sizes-default | Default-profile contract-size build and complete report |
| sizes | Size-profile contract-size build and strict deployable EIP-170 check |
| gas | Foundry gas report and gas snapshot |
| test | Final status gate: fail unless all six jobs succeed |

Every procedure from the prior serial workflow remains in the new workflow. The final aggregate job keeps the existing required check name `test` and has `if: always()` so a failed or cancelled prerequisite cannot produce a green aggregate result. Do not use an optional check configuration to bypass the six jobs.

## Build reuse

The protocol, size, and gas jobs restore Foundry `cache/` and `out/` directories by profile-specific keys. Changes to the Foundry configuration, Solidity sources, dependencies, and tests change the cache key. Foundry must still validate the restored compiler outputs before use. Do not cache the RPC secret.

## Artifacts

Both default-profile and size-profile `forge build --sizes` reports can exit nonzero when they list oversized test-only harness contracts. The workflow retains that report and tolerates only this specific Foundry EIP-170 size warning. The subsequent size-profile build and deployable EIP-170 enforcement script remain strict. Other compilation errors still fail the report steps.

The `gas-results` artifact includes `gas-report.txt` and `.gas-snapshot`. The `contract-sizes-default` and `contract-sizes-size-profile` artifacts each include the complete report from their respective profile. This replaces one combined artifact with two focused artifacts. Both reports remain available to the operator.

## Timing and acceptance

The previous sequential workflow took about 29 minutes on a successful run. Unit/fuzz, contract sizes, and gas report accounted for most elapsed time. Parallel jobs should reduce the critical path, but the new workflow needs measured runs before a new duration claim is valid.

Compare total wall-clock time from the first runner start to the completion of the `test` gate. Track cache hits, job queue delay, Foundry compilation time, and gas snapshot stability. If CI cost rises, tune runner and cache usage. Do not remove any validation procedure.

## Deployment scope

This is a CI-only change. It does not modify Solidity contracts, matching behavior, oracle, accounting, SDK calls, or operator runtime.

## Parallel compiler profiles

The default and size profiles compile on separate runners at the same time. The size-profile job runs the deployable EIP-170 check after its build. The existing required `test` status fails unless both size jobs and all other validation jobs succeed. Each profile has a separate cache namespace and a separate report artifact. Compare wall-clock duration with run #1195, which compiled each profile in about 4.5 minutes sequentially. Cache misses and runner queue time can affect the result.

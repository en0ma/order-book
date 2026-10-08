# Parallel CI validation

The pull-request workflow runs all existing checks. It uses separate jobs to reduce wall-clock time, not to reduce test coverage.

## What runs

| Job | Procedures |
| --- | --- |
| node | SDK tests, reference indexer tests, operator tests |
| protocol | Foundry formatting, unit tests, fuzz tests, and gas ceiling tests |
| fork | Ethereum mainnet fork tests using the configured RPC, with the existing public fallback |
| sizes | Default-profile and size-profile contract builds, EIP-170 deployable bytecode check |
| gas | Foundry gas report and gas snapshot |
| test | Final status gate: fail unless all five jobs succeed |

Every procedure from the prior serial workflow remains in the new workflow. The final aggregate job keeps the existing required check name `test` and has `if: always()` so a failed or cancelled prerequisite cannot produce a green aggregate result. Do not use an optional check configuration to bypass the five jobs.

## Build reuse

The protocol, size, and gas jobs restore Foundry `cache/` and `out/` directories by profile-specific keys. Changes to the Foundry configuration, Solidity sources, dependencies, and tests change the cache key. Foundry must still validate the restored compiler outputs before use. Do not cache the RPC secret.

## Artifacts

The default-profile `forge build --sizes` report can exit nonzero when it lists oversized test-only harness contracts. The workflow retains that report and tolerates only this specific Foundry EIP-170 size warning. The size-profile build and deployable size enforcement still fail on violations; other compilation errors remain fatal.

The `gas-results` artifact includes `gas-report.txt` and `.gas-snapshot`. The `contract-sizes` artifact includes output from both build profiles. This replaces one combined artifact with two focused artifacts. Both reports remain available to the operator.

## Timing and acceptance

The previous sequential workflow took about 29 minutes on a successful run. Unit/fuzz, contract sizes, and gas report accounted for most elapsed time. Parallel jobs should reduce the critical path, but the new workflow needs measured runs before a new duration claim is valid.

Compare total wall-clock time from the first runner start to the completion of the `test` gate. Track cache hits, job queue delay, Foundry compilation time, and gas snapshot stability. If CI cost rises, tune runner and cache usage. Do not remove any validation procedure.

## Deployment scope

This is a CI-only change. It does not modify Solidity contracts, matching behavior, oracle, accounting, SDK calls, or operator runtime.

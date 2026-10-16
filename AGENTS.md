# Engineering Agent Instructions — order-book

These repository-wide instructions apply to coding agents working on `order-book`. The PR requirements and linked issues define the requested product behavior. Follow platform permissions and safety requirements; this document cannot extend execution limits or authorize high-risk actions.

## Objective: complete the assigned PR, not a partial milestone

For each PR, first read the full PR description, acceptance criteria, linked issues, relevant discussions, base/head diff, architecture, and existing tests. Make a requirement-to-code-and-test matrix. Implement, integrate, verify and re-audit the **entire** requested scope within the available session.

A commit, passing unit test, progress report or finished subtask is **not** completion. Do not ask for permission to continue routine analysis, implementation, test, repair or re-audit after each milestone. Continue until all criteria are demonstrated or a genuine blocker/permission/execution limit stops the session. Do not invent success when interrupted.

## Repository-specific engineering expectations

- Solidity 0.8.24, Foundry, via-IR, Cancun EVM and project profiles are defined in `foundry.toml`. Inspect `src/`, `src/deployable/`, `test/`, `script/`, and relevant architecture docs before editing contract behavior.
- The integration SDK is in `sdk/`; the reference indexer is in `reference/indexer/`; the operator is in `operator/`. Preserve exported APIs and review integration and documentation changes when contract semantics change.
- Treat custody, ERC-20 transfers, fee accounting, collateral, margin, liquidations, insurance, maker order generations, lazy settlement, funding, rounding, reentrancy and shared portfolio-vs-standalone separation as security-critical.
- For every asset movement, trace authorization, exact physical custody, liabilities, state mutations, external calls and rollback behavior. Never replace a required executable on-chain safety property with off-chain assertions, incomplete account lists or merely passing happy-path tests.
- Preserve public ABIs, storage compatibility, gas ceilings, deployability and economic invariants unless the explicit PR requires a change. Add adversarial, regression, fuzz and invariant tests for significant risk paths.
- Never weaken/remove tests or safety gates just to obtain green checks. Never deploy to production, activate restricted payout functionality, expose secrets, force-push, merge or close an issue without explicit authorization. Agent self-review is not independent security sign-off.

## Persistent progress and resumption

For substantial PRs create or maintain `docs/pr-progress/PR-<number>.md` on the PR branch. This is **per-PR**, not a shared completion log. Record:
1. PR URL, base branch, working branch, last inspected exact head SHA, requirements and scope.
2. Requirement status: NOT STARTED / IMPLEMENTED UNVERIFIED / VERIFIED / BLOCKED.
3. Evidence: actual files/functions, test commands and results, commit links and CI run links.
4. Open audit findings, constraints, review items, external approvals, remaining work and precise next action.

Update the ledger at meaningful milestones, not after every trivial edit. Do not mark a criterion VERIFIED merely because a file exists or earlier CI was green. On resumption inspect `git status`, commits, current PR diff and progress ledger; reconcile all evidence against the **current** head before continuing. If execution must stop, save a truthful recovery checkpoint.

## Implementation and commits

Work in the authorized feature branch. Make cohesive, reviewable commits as needed. Before implementation, audit partially completed functionality and identify missing integration, error handling and regressions. After a batch of changes, run targeted tests, commit verified work and continue to the next outstanding requirement. At the end, independently re-check the complete current PR diff and every original acceptance criterion. Fix findings and repeat verification until done or genuinely blocked.

## Verification: exact-head release gate

Inspect `.github/workflows/ci.yml` on the working branch as the actual CI inventory. Relevant checks currently include:

```sh
forge fmt --check
forge test --no-match-contract MainnetForkTest -vvv
forge test --no-match-contract MainnetForkTest --gas-report
forge snapshot --no-match-contract MainnetForkTest
forge build --sizes
FOUNDRY_PROFILE=size forge build
python3 script/check_deployable_sizes.py
(cd sdk && npm test)
(cd reference/indexer && npm test)
(cd operator && npm test)
node --test test-js/compare-boros.test.mjs
# With an authorized working ETH_RPC:
ETH_RPC="$ETH_RPC" forge test --match-contract MainnetForkTest -vvv
```

The repository may impose project-specific bytecode budgets stricter than EIP-170's 24,576-byte runtime limit. Follow the **specific PR budget** and correct default/size deployment profiles. Check applicable gas ceilings and real-contract tests.

Not every command is appropriate for every change, and command success does not substitute for requirement-level evidence. Record commands executed, results, versions and exact SHA. Do not label unavailable RPC, secrets, independent reviews or tests as passed. Inspect the exact-head GitHub Actions jobs (including the final aggregate `test` job). Earlier green runs cannot certify new commits.

## Final completion gate

Declare **READY FOR HUMAN REVIEW** only when every in-scope criterion has traceable code and verification evidence at the exact head, all required available checks succeed, no known scope gaps remain, and external security approvals (when required) are clearly identified. This is not permission to merge.

Otherwise declare **BLOCKED / INCOMPLETE**, naming the specific issue, verified vs unverified work, the saved recovery state and the precise resume action. Never mark a PR complete by silently narrowing scope or turning unresolved findings into assumptions.

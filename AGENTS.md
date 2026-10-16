# Engineering Agent Instructions — order-book

These instructions apply to every coding task in this repository. Follow the PR description, applicable issues, and existing architecture documentation as the source of product requirements. Do not let these instructions override higher-priority safety or platform restrictions.

## Mission and continuation

Own the *whole assigned change*, not just the next edit. For a PR, inspect its base/head diff, full description, acceptance criteria, review threads, linked issues, and relevant code before changing files. Build a requirement-to-code-and-test matrix and keep implementing, integrating, testing, and re-auditing within the available execution session. A commit or progress summary does **not** mean the PR is complete. Do not ask whether to proceed after ordinary milestones; these steps are already part of the task.

A session can still end because of execution limits, unavailable credentials, external approvals, or a genuine product ambiguity. Never claim to have overcome these restrictions. Before stopping incomplete work, persist the exact branch/head SHA, completed and pending criteria, commands and outcomes, blockers, and next action. On resume, reconcile this report against current Git state instead of blindly trusting prior summaries.

## Repository architecture and trust boundaries

- Solidity 0.8.24, Foundry, via-IR and EVM Cancun are configured in `foundry.toml`. Contract sources and tests live in `src/` and `test/`; deployable contracts are under `src/deployable/`.
- The TypeScript SDK is in `sdk/`, the operator in `operator/`, and the reference indexer in `reference/indexer/`. Review changes to exported interfaces, integration, deployments, and documentation when contracts change.
- Read `README.md`, `docs/SYSTEM_ARCHITECTURE.md`, `docs/ARCHITECTURE.md`, `docs/INTEGRATION_FLOWS.md`, and the relevant issue-specific design document as needed.
- Treat ERC-20 custody, accounting, collateral, fee distribution, liquidation rewards, maker settlement, funding, insurance, and portfolio segregation as security-critical. No off-chain attestation or incomplete claimant enumeration may silently replace an explicitly required on-chain invariant.
- Never expose keys, broadcast real deployments, activate treasury payouts, or perform irreversible chain operations merely to make tests pass. Require explicit approval and appropriate independent review for deployment/security-critical changes.

## Planning and persistent evidence

For substantial PRs, maintain `docs/pr-progress/PR-<number>.md` on the working branch (or a clearly named equivalent if one already exists). Include:
1. PR URL, base branch, current head SHA, scope and acceptance criteria.
2. Requirement-by-requirement status: NOT STARTED / IMPLEMENTED UNVERIFIED / VERIFIED / BLOCKED.
3. Exact files/functions changed, proof or test evidence, relevant commands and results.
4. Open defects, known limitations, review threads, CI status, and next work item.
5. A timestamped final audit tied to the **exact** commit SHA.

Do not mark requirements VERIFIED solely because code exists, tests were written, a prior commit passed, or a checklist was previously checked. Keep speculative claims separate from observed results. Minimize noisy progress commits; use coherent implementation commits and update the progress report at meaningful checkpoints.

## Implementation discipline

- Prefer minimal, reviewable changes that preserve existing public ABIs, storage layouts, integration contracts, economic semantics, and deployment profiles, unless explicit requirements demand otherwise.
- Follow all value movements and accounting mutations across *both* standalone Core and shared portfolio custody where applicable. Check for signed-netting errors, stale/lazy maker and funding obligations, rounding, reentrancy, malicious ERC-20 behavior, and conservation under rollback.
- Add or update real-contract tests for intended behavior, failure conditions, adversarial cases, and regressions. Do not remove or weaken assertions, security gates, size limits, or tests to obtain green results.
- Make multiple logical commits as needed on the authorized feature branch. Do not force-push, merge, alter unrelated work, or close linked issues without explicit authorization.

## Verification gates

Use `.github/workflows/ci.yml` as the authoritative CI inventory, and inspect it for changes rather than assuming these commands cover everything. For relevant changes, run and record:

- `forge fmt --check` (or the repository's CI formatting step)
- `forge test --no-match-contract MainnetForkTest -vvv`
- `forge test --no-match-contract MainnetForkTest --gas-report`
- `forge snapshot --no-match-contract MainnetForkTest`
- `forge build --sizes`
- `FOUNDRY_PROFILE=size forge build` and `python3 script/check_deployable_sizes.py`
- `npm test` in each of `sdk/`, `reference/indexer/`, and `operator/`
- `node --test test-js/compare-boros.test.mjs`
- The mainnet-fork test job with an authorized, working `ETH_RPC`, when required.

The project's additional **23,000-byte Core runtime budget** is stricter than EIP-170's 24,576-byte limit: verify both, against the correct deployment profiles. Preserve the repository's gas ceilings. Some tests require network access or secrets; report them as NOT RUN/BLOCKED rather than PASS if unavailable.

Check GitHub Actions at the **final exact head SHA**, including the final `test` aggregation job and all dependent jobs. An earlier green commit does not certify later changes. Never invent test or CI outcomes.

## Special release gate for issue #203 / PR #211

Read `docs/ISSUE_203_ONCHAIN_SOLVENCY_IMPLEMENTATION.md` and PR #211's full acceptance criteria. Before claiming fee-payout readiness, establish the executable on-chain protected-liability invariant for each exact physical custody domain, including claimant completeness, positive cash claims, maker execution and lazy rebates, unsettled funding, insurance, bad debt, rounding, and liquidation rewards. Analyze standalone and multi-market portfolio assets separately. Address bounded-gas feasibility, authorized recipients and ledger debits, adversarial token behavior, exact-head gas/size/fork validation, and any independent security review requirement.

Fail closed where proof is unavailable. Do not activate payouts, declare solvency proven by a diagnostic, or close issue #203 based on partial work. A conservative restriction is not automatically acceptance of missing functionality: document its effect on the original criteria and request human scope decisions when necessary.

## Final audit and reporting

Perform a fresh requirement-by-requirement audit of the *complete final diff* and integration points after changes. Fix findings and rerun affected verification in the same session when feasible.

End with exactly one truthful status:
- **READY FOR HUMAN REVIEW:** Every scoped acceptance criterion has grounded implementation and verification evidence at the exact head, with external approvals/independent security sign-offs separately identified.
- **BLOCKED / INCOMPLETE:** Explain the genuine blocker or execution limit, what is verified, what is not, preserved progress, and the precise resume action.

The agent never performs the final merge or substitutes self-review for independent security assessment.

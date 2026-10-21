# Issue #203 / PR #211 — release-validation follow-up

This document tracks the **remaining acceptance blockers** separately from the implementation in draft PR #211. This follow-up branch is stacked on PR #211's `491e862c808013b937145a8bd7017575a8f47035` head. **It must not be merged into `main` independently of a validated PR #211.**

## Release blockers (unverified, not waivers)

- [ ] Compile the exact PR #211 head under `FOUNDRY_PROFILE=size forge build` and `python3 script/check_deployable_sizes.py`. Core deployed bytecode must be **at most 24,576 B**, including EIP-170. Revised project budgets are Core 24,576 B, vault 4,500 B and portfolio coordinator 8,500 B. Do not alter EIP-170.
- [ ] Run `forge test --no-match-contract MainnetForkTest -vvv`, then rerun targeted liquidation-reward and portfolio/standalone fee-solvency tests, plus full fuzz/invariant and gas ceilings.
- [ ] Resolve all failures in the exact-head tests. On an **older** head (`d4eb692`), 523 tests passed and 10 failed, and the Core was 25,290 B; those figures **are not measurements of the current head**.
- [ ] Verify the last workflow trigger changes by examining *all* Actions events in GitHub, including `push` and `workflow_dispatch`. The GitHub connection's `fetch_commit_workflow_runs` result only covers PR-triggered runs, so its empty result cannot prove that no push run exists.
- [ ] Run SDK, indexer, operator, fork, docs and EVM security validations, verify accepted rollback behavior for ERC20 callback/extra debit, and obtain independent review of executable payout gates.
- [ ] Keep both protocol fee distribution switches **disabled** pending the complete proof, sign-off and deployment checks.
- [ ] Only then move #211 from draft to ready and merge it; close issue #203 after verified merge evidence.

## Rejected early merge

On October 16, 2026, GitHub rejected an attempted merge of PR #211 with HTTP 405: `Pull Request is still a draft`. That is **not** a successful merge, and must never be represented as one.

## Branch/PR sequencing

1. Treat #211 as the implementation base. This follow-up PR is stacked against `feature/issue-203-onchain-net-liability-solvency`, not `main`.
2. Fix failing validations here or in #211, and keep a head-specific record of the passing results.
3. After #211 becomes validated and merges to `main`, retarget/rebase the follow-up onto `main` if any follow-up changes remain. Never merge a verification-only document as substitute for successful security acceptance.

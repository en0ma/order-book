# PR #208 release scope — deferred treasury fee distribution

PR #208 delivers Workstream A custody, liquidation, inventory-cleanup,
and fail-closed market-retirement hardening.

## Explicitly out of scope for this merge

The **on-chain** net-liability-aware protocol-fee distribution mechanism originally
specified in #171 is **not implemented or accepted** here. That specification was
closed as superseded, and its substantive remaining obligations continue under
consolidated issue #203. Future fee distribution needs a separate reviewed
implementation and independently green CI before any treasury transfer.

PR #208 does **not** authorize treasury fee distribution:
- No new treasury fee-withdrawal entrypoint is introduced.
- Managed portfolio-vault owner `sweepExcess` remains disabled when a
  controller is configured.
- Operator claimant-replay and fee-surplus calculations are diagnostics only,
  **not** on-chain proof or authority to transfer tokens.
- Existing liquidation reward payments remain available subject to their
  current ledger checks and tests; they are **not** treasury withdrawals.
- Any future payout mechanism must prove conservative liabilities in the
  same physical custody domain, including maker/funding/insurance obligations,
  before paying out.

## Merge contract

Merge this PR only after exact-head formatting, unit/fuzz, mainnet fork,
SDK/operator, gas, contract-size, security, and documentation checks are green;
record every pushed commit individually in the PR body and resolve review
threads. Defer any attempt to enable treasury payout to the #203 follow-up.

This scoping change does not claim that #171's payout solvency requirements
have been implemented or that a diagnostic certificate makes fees distributable.

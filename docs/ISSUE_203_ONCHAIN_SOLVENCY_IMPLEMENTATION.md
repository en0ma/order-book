# Issue #203 — complete on-chain fee-solvency implementation contract

## Scope and non-negotiable release boundary

This branch is the **full implementation workstream**, not a narrow diagnostic PR.
Until **all** gates below are implemented, audited and tested, the PR stays draft,
and no treasury fee withdrawal is enabled. PR #208 already merged and hardens
custody/liquidation/retirement while explicitly deferring this proof.

## Implemented proposal (not yet release-authorized)

This draft branch includes disabled-by-default, governance-controlled treasury
payout entrypoints for standalone Core and shared portfolio coordinator/vault.
They use independent on-chain claimant registries, exact physical custody
balances, positive-only customer liabilities, insurance and escrowed rebates,
and immutable portfolio topology. An immutable verifier is invoked before
and after every proposed ERC20 transfer; portfolio mode debits the originating
market fee ledgers atomically.

**Conservative limitations:** new treasury payouts require every market
position and maker/advanced order to be fully settled. Standalone verification
has a 64-claimant maximum; portfolio verification has 64 raw registry entries,
a 256 account-market-pair limit and a maximum of 32 markets. Deployments
exceeding these caps **cannot distribute fees** through these methods.
The registries are constructor-bound and do not retroactively certify
historical unenumerated deployments. This is a denial-of-payout limitation,
not permission to omit claimants.

Liquidation rewards use a separate on-chain conservative bound over positive
marked account claims, per-side/per-execution-tick unassigned maker exposure,
gross pending funding bases, maker rebate escrow, insurance reserves and
rounding dust. If the bounded proof is unavailable or capacity is insufficient,
the **reward is capped or skipped without reverting liquidation**. This must
be independently reviewed for rounding coverage and economic liveness.

The implementation has not yet passed exact-head release validation. No
deployment should activate the payout toggle or treat these diagnostics as
production-reviewed authorization until all checklist gates, bytecode/gas
budgets, and external review are satisfied.

## Physical custody and protected claim invariant

For every permitted external protocol-fee payout from a standalone Core, at
the point of transfer the protocol must establish the checked inequality:

`ERC20.balanceOf(core) - payout >= protectedLiabilities(core)`

No off-chain certificate, unsigned operator assertion, caller-selected roster
or sampled account list is sufficient to authorize this on-chain predicate.
Portfolio market fees cannot be paid from shared-vault backing without a
**separate comprehensive portfolio-domain proof**; otherwise keep those
external payouts disabled.

The protected liability bound must conservatively account for:
1. Signed settled cash held for **all** accounts, including non-offsettable
   positive claims, realized trade/funding effects and already-withdrawn cash.
2. Outstanding maker execution value across current and closed quote
   generations; neither signed global `pendingMakerTradeCashflow` nor lazy
   maker funding entries may be used without proving cancellation-safe bounds.
3. Unsettled maker rebates from the high 128 bits of `_feeAccountingPacked`,
   including generation closing and rounding tails.
4. Current and future-position funding accrued since every account and maker
   checkpoint, with a sound conservative upper bound or mandatory settlement.
5. Insurance reserves and bad-debt obligations, without double counting funds
   that have moved between claim categories.
6. Market isolation: standalone Core and portfolio-vault ERC20 balances must
   not be added together to justify a withdrawal from only one of them.

## Mutation audit — required for any payout endpoint

Review and reconcile **every** accounting transition:
`depositCollateral`, `withdrawCollateral`, `_debitSettledCash`,
`_applyImmediateTakerFill`, `_applyMakerPositionCashflow`,
`_settleFundingForQuote`, `_settleExistingPositionFunding`,
maker-rebate release/reclaim, open/closed generation rounding-tail settlement,
`moduleCoverBadDebt`, `fundInsurance`,
`allocateProtocolFeesToInsurance`, and `modulePayLiquidationReward`.
A skipped mutation invalidates an incremental liability accumulator.

## Required adversarial contract evidence

- Legitimate funded liquidation rewards still work without synthetic donations.
- Zero, partial, capped, over-accrual and under-backed payouts are handled
  atomically, with treasury recipient permissions independently reviewed.
- Both signs of funding index moves, quote top-ups, lazy maker and closed-
  generation settlement preserve the liability bound before/after settlement.
- Positive liabilities of unrelated accounts are never cancelled by one
  account's negative equity; bad debts cannot manufacture distributable fees.
- Shared portfolio custody cannot be swept, even when a token donation makes
  `balance - totalAccountedCollateral` appear positive.
- Reentrant/fee-on-transfer/extra-debit and transfer-failure tokens revert
  payouts without ledger or custody drift.
- All production and test contracts compile under the 23,000-byte Core
  project budget and EIP-170; exact-head fork/gas/fuzz/security/docs pass.

## Completion check

A PR may become ready for review **only** after the complete on-chain
conservative bound, fee-transfer authorization, all-account/maker/funding
invariants, standalone/portfolio segregation, real-contract tests, zero
unresolved reviews, and exact-head CI are demonstrated with linked commits.
No diagnostic off-chain attestation satisfies these requirements.

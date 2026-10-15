# Workstream A: implementation checklist

Tracks #203. This commit contains **planning only**; all implementation tasks remain outstanding.

- [ ] Prove net-liability solvency before any treasury fee distribution; preserve disabled withdrawals until proof passes (#171)
- [ ] Integrate two/multi-market portfolio and standalone custody invariants, negative equity, funding, insurance and lazy maker/rebate claims (#172, #179)
- [ ] Finish zero/partial-liquidity liquidation, recovery stopping, liquidation rewards and residual position/debt lifecycle (#173)
- [ ] Enumerate/clean maker, conditional, trailing and strategy order inventory atomically under liquidation (#174)
- [ ] Guard market retirement and migrations against open positions, outstanding claims and unsafe collateral transitions (#183)
- [ ] Add real-contract adversarial/ERC20 callback/failure tests, fuzz/stateful conservation and settlement reconciliation
- [ ] Run exact-head unit/fuzz/fork/gas/size/security CI; resolve reviews; merge only if green

The PR description is the authoritative live checklist. Update its boxes only with implementation commits and tests.

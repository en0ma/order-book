# Workstream C: implementation checklist

Tracks #205. This commit contains **planning only**; all implementation tasks remain outstanding.

- [ ] Inventory deployed contract ABI and canonical event coverage; fail closed on unknown or omitted canonical event signatures (#181)
- [ ] Reconcile decoded maker/order/portfolio histories with authoritative on-chain reads at deterministic checkpoints (#181)
- [ ] Implement rollback/reorg recovery and migrated-market checkpoint verification without silent replay corruption (#181, #182)
- [ ] Implement idempotent keeper/API operation plans, transaction nonce replacement and duplicate submission protection (#182)
- [ ] Exercise stale provider, RPC failure, retry, replacement, replay, reorg and inconsistent-state adversarial tests (#182)
- [ ] Document operator interfaces, ownership boundaries, chain/network config and deployment/recovery procedures
- [ ] Run exact-head SDK/operator/contracts/fork/gas/size/security CI; resolve reviews; merge only if green

The PR description is the authoritative live checklist. Update its boxes only with implementation commits and tests.

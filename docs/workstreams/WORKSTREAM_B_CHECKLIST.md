# Workstream B: implementation checklist

Tracks #204. This commit contains **planning only**; all implementation tasks remain outstanding.

- [ ] Enforce and test full risk-on vs risk-off emergency permission matrix across Core, advanced orders, liquidation and portfolio admission (#175)
- [ ] Prove guardian-only pause, governance-only resume, settlement/cancel/deposit/reduce and safe withdrawal availability during outages (#175)
- [ ] Implement deterministic funding publication preflight: chain identity, index checkpoints, bounded cadence/delta, stale/replay and catch-up reconciliation (#176)
- [ ] Bind oracle source identity, market/quote units, scaling, heartbeat and configured Core source; reject mismatch (#177)
- [ ] Exercise primary/backup outages, sequencer failures, replay-proof restoration and operator-only transitions (#178)
- [ ] Provide funding authority rotation/event replay/drift detection alerts and staged operator recovery (#180)
- [ ] Add adversarial staged integration/fuzz tests and deployment evidence; preserve feed-independence external-attestation requirement
- [ ] Run exact-head unit/fuzz/fork/gas/size/security/docs CI; resolve reviews; merge only if green

The PR description is the authoritative live checklist. Update its boxes only with implementation commits and tests.

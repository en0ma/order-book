# One canonical recovery state

Keep the index checkpoint and the strategy registry snapshot at one canonical head. Call `assembleRecoveryBundle` only after both components use the same block number and hash. Store the bundle as one atomic record. On restart, call `validateRecoveryBundle` before restoring either part. The validator parses both state payloads in isolated instances, so a malformed record cannot cause one live component to restore alone. Never restore an index state from one fork with strategy records from another fork.

## Keeper admission

Use `executeReadyTasks` for existing conditional, trailing, resting, and liquidation keeper tasks only after the index snapshot passes the safe-head readiness check. The helper requires matching checkpoint and published snapshot heads. It retains the branch-epoch idempotency key and simulates each task before submit. It does not implement RPC, transaction signing, or live head rechecks. The required `CanonicalHeadVerifier` reads the current canonical block hash from a trusted RPC before work and again after simulation, immediately before each submit. It rejects same-height reorgs. The caller must still prevent changes between this check and transaction inclusion.

Strategy task execution remains separate. Before calling `refreshIceberg`, `executeTWAPSlice`, or `syncPegged`, fetch the current authoritative contract state and simulate the call. Do not mix future TWAP admission into stored index state.

## Recovery procedure

1. Stop keeper submissions and mark HTTP readiness as unavailable.
2. Check the RPC chain ID and compare the indexed head with the canonical chain.
3. Roll back retained orphan blocks or restore the last trusted checkpoint. A deep reorg outside retained history requires an operator-controlled rebuild.
4. Replay Core and strategy lifecycle events to the same canonical head.
5. Verify both heads and write one atomic recovery bundle.
6. Read current diagnostics, mark prices, and strategy states.
7. Enable data routes and keeper calls only after the safe-head checks pass.

This path supplies consistency rules, not a hosted database, RPC, or signer. It does not prove finality, collateral solvency, or trade execution.

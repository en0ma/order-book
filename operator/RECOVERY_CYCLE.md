# Canonical operator replay cycle

`runRecoveryCycle` is a transport-neutral reference coordinator. It reads the chain ID and safe head, checks one stored recovery bundle, and replays Core and strategy lifecycle events from that checkpoint. It builds the read model only after it validates both states and stores a new atomic bundle. The caller must publish the returned model only after the cycle succeeds.

## Steps

1. Load a saved bundle by deployment identity.
2. Validate Core and strategy payloads in isolated instances.
3. Check the saved block hash against a trusted RPC.
4. Replay a bounded set of canonical blocks in both state machines.
5. Check the final block hash again.
6. Save the complete bundle in one atomic store operation.
7. Publish the returned read model only after the save finishes.

The cycle does not submit keeper tasks. Use the separate keeper admission gate after read-model promotion and fresh chain verification.

## Limits

The reference implementation does not recover an orphaned stored checkpoint by itself. It rejects that checkpoint and requires the operator to restore a trusted older checkpoint or rebuild from the deployment block. A bounded sync pass can be behind the safe head; its read model reports not ready until the operator catches up.

The store interface does not guarantee atomicity. The adopting team must implement it with a database transaction or atomic file replace. The RPC adapter must supply canonical block events. Transaction relay, WebSocket delivery, finality guarantees, HTTP authentication, and signing remain operator responsibilities.

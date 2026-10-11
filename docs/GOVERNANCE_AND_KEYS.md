# Governance, Privileged Roles and Key Operations

The DEX team manages its own keys and protocol administration. The reference deployment script initially wires the contracts and then transfers authority to `PROTOCOL_ADMIN`.

## Permission matrix

| Role | Contract / entrypoint | Authorized action | Important restriction |
| --- | --- | --- | --- |
| Core owner | `OrderBookCore.transferOwnership`, `setFundingUpdater` | Transfer ownership and rotate funding authority | Compromise can override wrapper funding constraints |
| Core owner | `setRiskIncreasePaused` | Pause or unpause new risk | Unpause must come from owner |
| Funding updater | `setFundingIndex` | Publish a signed funding index | No intrinsic cadence/delta check in Core |
| Funding updater | `setRiskIncreasePaused(true)` | Emergency risk-off | Cannot unpause using updater-only authority |
| Advanced module owner | Advanced configuration entrypoints | Wire authorized strategy, maker and liquidation modules | Check one-time configuration restrictions |
| Liquidation module owner | `configureLiquidatorReward` | Configure reward rules | Review limits and reserve exposure |
| Keeper signer | Permissionless eligible execution functions | Submit on-chain work | A keeper is not automatically Core owner |
| Market maker | Quote submission and maker settlement | Manage its own quote state | It is not an admin role |
| Oracle source/controller | Adapter-specific oracle updates | Change on-chain mark / extrema inputs | Rights depend on selected adapter |
| Portfolio controller | Core risk-module functions | Route portfolio market actions | Only the configured controller is accepted |

## Deployment authority flow

```text
Secure broadcaster
   ├─ deploy contracts
   ├─ set one-time module wiring
   ├─ assign initial funding updater
   └─ transfer Core, Advanced and Liquidation ownership
           ↓
    Team governance owner (for example Safe / timelock)
           ├─ approves routine config changes
           ├─ rotates funding authority
           └─ manages incident risk-off policy
```

A Safe or timelock is a recommended team arrangement, **not** a contract that this repository automatically deploys.

## Funding authority and emergency controls

The Core owner can change the funding updater at any time through `setFundingUpdater`. The new updater can then call `setFundingIndex`. The optional `BoundedFundingUpdater` limits updates submitted *through it* but cannot verify an index change made through another temporarily authorized updater. Monitor `FundingUpdaterChanged` and `FundingIndexUpdated` on-chain. Treat unapproved rotation as an incident.

The updater can call `setRiskIncreasePaused(true)` to halt new risk. It cannot reverse the pause unless it is also the Core owner. Only the owner should authorize recovery after oracle, ledger and indexer checks.

## Key rotation runbook

1. Confirm the current deployed contract owner and funding updater through direct chain reads.
2. Verify the receiving address, chain ID, Safe signers and timelock policy.
3. Create a proposed transaction and simulate it on the correct network.
4. Apply multi-party review. Do not reuse a signing key from a keeper for governance.
5. Broadcast the rotation; verify emitted events and current authority.
6. Update the deployment manifest and any strict operator verification expectation.
7. Reconfigure independent monitoring for the new addresses. Reconcile funding events since the last checkpoint.
8. Revoke old off-chain signer credentials and document the incident or scheduled change.

**One-step ownership transfers need special care.** Confirm the receiving contract or Safe can execute the owner functions before transferring control. Test the process on staging first.

## Suggested separation of duties

- Governance Safe or timelock: Core, Advanced and Liquidation ownership.
- Funding operator: publishes bounded updates and monitors cadence.
- Keeper and liquidation signers: permissionless execution only.
- Oracle publisher: only the selected adapter's data-update rights.
- Market-maker signers: independent trader/maker accounts.
- Watcher: read-only authority, index, oracle and custody alerts.

See [Parameter Reference](PARAMETER_REFERENCE.md) and [Team Handbook](TEAM_HANDBOOK.md).

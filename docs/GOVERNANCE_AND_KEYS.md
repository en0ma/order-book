# Governance, Privileged Roles and Key Operations

The DEX team manages its own keys and protocol administration. The reference deployment script initially wires the contracts and then transfers authority to `PROTOCOL_ADMIN`.

![governance funding flow](/docs/assets/diagrams/governance-funding-flow.svg)

[Edit the diagram source](https://github.com/en0ma/order-book/blob/docs/site-quality-gates-and-visuals/docs/assets/diagrams/source/governance-funding-flow.drawio).

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

See [Parameter Reference](/docs/PARAMETER_REFERENCE) and [Team Handbook](/docs/TEAM_HANDBOOK).

## Independent pause-only guardian through bounded updater

If `BoundedFundingUpdater` is assigned as the Core's funding updater, its configured funding `operator` may set or revoke a distinct `riskOffGuardian`. The guardian may call `pauseRiskIncrease()` on the wrapper, which forwards only `setRiskIncreasePaused(true)` to Core. It cannot call `publish` or lift the pause. The wrapper emits `RiskOffGuardianChanged` on rotation. Funding-operator control of guardian rotation is **not** a replacement for owner-governed Core role management: deployment governance must approve the guardian, monitor rotations and keep the wrapper installed as funding updater. The Core owner alone unpauses. This avoids increasing near-budget Core runtime bytecode.


### Bounded funding authority governance recovery

The BoundedFundingUpdater deployment account is immutable `governance` and can nominate a replacement publication operator. A proposed operator must explicitly call `acceptOperator`; a later nomination replaces an earlier unaccepted nominee. This separates publication rights from recovery rights. On acceptance, the old operator loses publication, pause-forwarding, and guardian-assignment privileges; any existing risk-off guardian is revoked and must be explicitly reappointed. The new operator may publish only within the existing elapsed-time/delta bounds and only if Core's authority and canonical index match the updater checkpoint. Rotating an operator **does not** repair a diverged funding index. Reconcile funding history before any privileged checkpoint restoration. Only the Core owner can clear risk-increase pause; neither operator nor guardian can unpause.

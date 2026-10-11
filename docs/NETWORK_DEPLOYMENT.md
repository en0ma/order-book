# Deploy to an EVM Network

This guide describes a **live-chain deployment**. The target can be Ethereum mainnet or another supported EVM network. Foundry provides the deployment transaction tooling; its local test environment is not the exchange's runtime.

**Audience:** Protocol deployer, governance signers, risk owner and infrastructure operator.

## Before you broadcast

Confirm each item with your team:

| Requirement | What to record |
| --- | --- |
| Target chain | Chain ID, mainnet RPC endpoint and block explorer |
| Source release | Git commit, compiler version, dependencies and deployed artifact hashes |
| Collateral ERC-20 | Verified chain address, decimals, custody assumptions and approval behavior |
| Price oracle | Verified chain address, expected tick mapping, freshness and publisher authority |
| Trading rules | Execution band, initial/maintenance margin, fees, liquidation reward and lot accounting scale |
| Governance | Safe or other governance address, emergency access and funding-updater address |
| Operations | Live indexer, persistent checkpoint store, keeper signers, liquidator and market-maker service |
| Release evidence | Review approvals, audit status, test results, deployment simulation and rollback plan |

The underlying perp asset is a market definition and oracle reference. The asset itself need not be the collateral token.

## 1. Prepare the deployment specification

Use `deployments/spec/schema/v1.json` as the schema and `deployments/spec/example.json` as a **shape reference only**. The example has placeholder addresses. Replace them with verified addresses on your target chain.

Use `validateDeploymentSpec` to reject invalid fields. Use `compileDeploymentEnvironments` to map the spec to Foundry inputs. Save the approved spec with your team's release artifacts.

For a standalone market, `script/DeployStandalone.s.sol` uses these variables:

```text
PROTOCOL_ADMIN
FUNDING_UPDATER
COLLATERAL_TOKEN
MARK_ORACLE
EXECUTION_BAND_TICKS
INITIAL_MARGIN_BPS
MAINTENANCE_MARGIN_BPS
TAKER_FEE_BPS
MAKER_REBATE_BPS
LIQUIDATOR_REWARD_BPS
COLLATERAL_UNITS_PER_LOT_TICK
```

Review the precise semantics in the [parameter reference](/docs/PARAMETER_REFERENCE). Several values are constructor-time or one-time settings. Changing them later may require a new deployment.

## 2. Simulate against the intended network

Export the approved configuration variables using your secure deployment tooling. Do not commit private keys, RPC credentials or signer secrets.

```sh
# RPC_URL points to the real target EVM network.
forge script script/DeployStandalone.s.sol:DeployStandalone \
  --rpc-url "$RPC_URL"
```

This command simulates the deployment. It does **not** send contracts to the network because `--broadcast` is absent. Confirm estimates, addresses, gas policy and owner handoff with the approved configuration.

A mainnet-fork `forge test` is another simulation path. It does not publish live contracts.

## 3. Broadcast the approved deployment

Only an authorized signer should broadcast the reviewed deployment. The example below uses Foundry's signing configuration; provision it through your team's secure key process.

```sh
forge script script/DeployStandalone.s.sol:DeployStandalone \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Ensure the broadcasting account and required signer options are configured before using this command. The script deploys Core, advanced order, execution strategy, market-maker, liquidation and read-lens contracts, wires the modules, assigns the funding updater and transfers Core/Advanced/Liquidation ownership to `PROTOCOL_ADMIN`.

**Important:** This script does not automatically deploy your Safe, indexer, keeper infrastructure or market-making bots.

## 4. Verify the live contracts

Before publishing a market to traders:

1. Wait for the chain-specific confirmation threshold.
2. Record the deployment transaction hashes, deployment block and contract addresses.
3. Confirm the address has contract code and attest the actual runtime bytecode against the approved release.
4. Read Core ownership, funding authority, oracle, collateral, accounting scale and configured module addresses directly from the chain.
5. Verify the Liquidation and Advanced module ownership and policies.
6. Build the manifest with `buildDeploymentManifest` and run the SDK's live deployment verifier.
7. Confirm that the manifest points to the **actual chain**, not a local Anvil or fork chain ID.
8. Publish the immutable release metadata and the verified manifest to the exchange frontend and backend.

See [governance and keys](/docs/GOVERNANCE_AND_KEYS) for owner rotation and funding authority risks.

## 5. Bring services online

| Service | Activation check |
| --- | --- |
| Indexer | Replay from each contract's deployment block and store canonical hashes |
| Trading API | Serve book/account views and expose data freshness |
| Frontend / SDK | Route signed transactions to the verified chain and contract addresses |
| Market makers | Submit quotes; verify partial fill accounting and inventory reconciliation |
| Keepers | Read current marks and simulate eligible advanced-order tasks |
| Liquidator | Track complete active-order registries and exercise closeout failure paths |
| Monitoring | Watch oracle freshness, RPC lag, reorgs, funding changes, liquidity and custody |
| Governance | Test emergency risk-off procedure and alert on unauthorized role changes |

Do not enable open-ended trading solely because contracts exist. Follow the staged acceptance checks in the [team handbook](/docs/TEAM_HANDBOOK).

## 6. Add markets or change configuration

For another **standalone** perp market, prepare and deploy another Core/module stack and register it in the exchange's off-chain market catalog. The Core has no generic `listToken` call.

**Portfolio mode requires separate planning.** The portfolio coordinator has a constructor-defined market set, not a generic dynamic `addMarket` method. Review migration and shared-collateral implications before expanding markets.

Read [market listing](/docs/MARKET_LISTING) and [parameter reference](/docs/PARAMETER_REFERENCE).

## Test environment versus live environment

| Activity | Where it runs | Does it publish contracts to mainnet? |
| --- | --- | --- |
| `forge test` | Local Foundry EVM | No |
| `forge test` with Ethereum mainnet RPC | Local fork reading mainnet state | No |
| `forge script --rpc-url` without broadcast | Simulated against target RPC | No |
| `forge script --rpc-url --broadcast` | Target chain | **Yes**, with an authorized signer |
| SDK live verifier | Read-only calls to target chain | No |

The fork security review tests contract behavior against real WETH state, but does not independently certify an exchange deployment.

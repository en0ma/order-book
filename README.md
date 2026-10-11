# Order Book

**A fully on-chain, pro-rata central limit order book for perpetual futures on EVM chains.**

Order Book provides smart contracts and integration tooling for teams building their own perpetual DEX. Trading, matching, collateral accounting, margin checks, funding and liquidation rules execute on-chain. Teams bring their own frontend, market makers, oracle source, infrastructure and governance.

The matching engine allocates fills **pro rata among makers at the same price**. It updates aggregate tick state during a trade and settles each maker's fills when that maker interacts. This avoids a per-maker write during taker execution.

## Architecture

![Exchange integration architecture](docs/assets/diagrams/dex-integration.svg)

*Blue: applications and services operated by the exchange team. Green: reusable integration libraries. Purple: EVM contracts. The contracts hold the authoritative order and account state; indexers provide read models and keepers submit eligible transactions.*

[Architecture and trust boundaries](docs/SYSTEM_ARCHITECTURE.md) · [End-to-end integration flows](docs/INTEGRATION_FLOWS.md) · [Editable diagram source](docs/assets/diagrams/source/dex-integration.drawio)

## What the engine includes

| Layer | Capabilities |
| --- | --- |
| **Order book** | 65,536 ticks, two-level occupancy bitmap, pro-rata price-level matching, maker shares, lazy maker settlement, IOC and FOK taker orders |
| **Order management** | Conditional orders, triggered limits, OCO/OTO orders, brackets, trailing stops, reduce-only constraints |
| **Markets and risk** | ERC-20 collateral, initial and maintenance margin, funding, execution bands, maker fees/rebates, liquidation and insurance accounting |
| **Market makers** | Managed quotes and batch refresh/cancel workflows, fills reconciled through share settlement |
| **Multi-market option** | Portfolio margin policy, collateral vault, admission coordinator and portfolio liquidations |
| **Integration** | TypeScript SDK, on-chain read lens, reference event indexer, keeper/liquidator planning libraries and versioned deployment specifications |

[Full feature catalog](docs/FEATURE_CATALOG.md) · [Contract internals](docs/ARCHITECTURE.md)

## How an exchange uses it

1. **Design a market.** Choose the chain, underlying price source, collateral token, order size, fees, margin rules and funding policy.
2. **Deploy contracts to the target chain.** Use the standalone deployment script or the reviewed portfolio deployment route. Transfer ownership to the team's governance address.
3. **Verify the deployment.** Check chain ID, module wiring, deployed bytecode, oracle, collateral, risk parameters and signers. Publish a deployment manifest.
4. **Connect the exchange.** Use the SDK for transaction plans, index on-chain events for the trading API, and integrate maker strategies.
5. **Operate the market.** Run keeper and liquidation services; monitor oracle state, indexer lag, funding, book depth, account risk and incident controls.

**This is a real-chain deployment model, not a Foundry fork deployment.** Foundry simulations and mainnet-fork tests are pre-deployment checks. Live contracts are deployed by broadcasting signed transactions to the intended network.

[Deploy to an EVM network](docs/NETWORK_DEPLOYMENT.md) · [List a market](docs/MARKET_LISTING.md) · [Parameters](docs/PARAMETER_REFERENCE.md) · [Governance and keys](docs/GOVERNANCE_AND_KEYS.md)

## Run the tests

Install the repository's configured Foundry toolchain, then run from the repository root:

```sh
forge test -vvv
forge test --gas-report
forge snapshot
```

The Ethereum mainnet-fork suite uses an RPC endpoint and the real WETH contract **on a local simulated fork**. It does not deploy the exchange to Ethereum mainnet.

```sh
ETH_RPC="$ETHEREUM_MAINNET_RPC" forge test --match-contract PerpLifecycleWethMainnetForkTest -vvv
```

For an actual deployment, follow the [network deployment guide](docs/NETWORK_DEPLOYMENT.md) instead.

## Documentation

| Task | Guide |
| --- | --- |
| Understand the modules and flows | [System architecture](docs/SYSTEM_ARCHITECTURE.md) |
| Integrate a frontend, API, indexer and keepers | [Integration flows](docs/INTEGRATION_FLOWS.md) |
| Configure and deploy to a real chain | [Network deployment](docs/NETWORK_DEPLOYMENT.md) |
| Add a perpetual market | [Market listing](docs/MARKET_LISTING.md) |
| Configure fee, margin and funding policy | [Parameter reference](docs/PARAMETER_REFERENCE.md) |
| Manage authority and emergency actions | [Governance and keys](docs/GOVERNANCE_AND_KEYS.md) |
| Run indexers, keepers and incident response | [Operator runbook](docs/OPERATOR_RUNBOOK.md) |
| Plan team responsibilities | [Team handbook](docs/TEAM_HANDBOOK.md) |
| Explore SDK and operator packages | [SDK](sdk/README.md) · [Operator](operator/README.md) · [Indexer](reference/indexer/README.md) |

### Design boundaries

The exchange team controls deployment, liquidity, token/oracle selection, keys and infrastructure. No hosted indexer, keeper or market maker is included. On-chain conditional orders still require transactions to execute. A liquidation cannot fill an order without opposite-side liquidity. The Core owner can rotate the funding updater; the optional bounded updater does not prevent that governance action.

This repository includes contract and fork tests, but those tests are not a substitute for an independent security assessment of a specific deployed exchange. See the [WETH fork security review](docs/SECURITY_REVIEW_WETH_FORK.md).

# Order Book Integration SDK

Dependency-free TypeScript helpers for teams integrating the deployable CLOB.

The SDK deliberately does not own RPC transport or signing. It produces typed transaction plans that can be handed to viem, ethers, a custom relayer, or another Ethereum client.

## Included

- declarative deployment-spec validation and Foundry environment compilation;
- canonical deployment-manifest construction from resolved deployment addresses;
- deployment manifest validation;
- manifest-driven live deployment verification plans;
- standalone vs portfolio routing for taker orders, maker liquidity, deposits and withdrawals;
- advanced-order transaction planning;
- OCO / OTO graph planning;
- reduce-only and minimum-fill planning;
- trailing-order planning;
- canonical packed market-maker quote encoding.

## Transaction plans

Each planner returns:

```ts
{
  target: "0x...",
  functionName: "take",
  args: [...]
}
```

The caller is responsible for ABI encoding, simulation, signing and submission.

## Deployment specs

Use `deployments/spec/schema/v1.json` to define a DEX deployment before broadcasting contracts. The spec contains the team's own protocol admin, collateral, market IDs, oracles, funding operators, fees, accounting scales and risk parameters.

`compileDeploymentEnvironments(spec)` emits the exact environment variables consumed by the repository's standalone or portfolio Foundry bootstrap. Standalone specs produce one environment bundle per listed market; portfolio specs produce one ordered multi-market bundle.

After deployment, `buildDeploymentManifest(spec, deployedAddresses, metadata, portfolio?)` combines the original source spec with actual deployed addresses and returns the canonical client/operator manifest. This keeps market ordering, portfolio indexes, oracle configuration and risk metadata derived from one source of truth.

## Deployment manifests

Use `deployments/schema/v1.json` as the canonical machine-readable schema. A sample document is available at `deployments/example.json`.

Manifest values should be generated from the actual deployment inputs and verified on-chain before publication. Do not copy the example addresses into a real deployment.

## Deployment verification

`OrderBookSDK.deploymentVerificationPlan()` returns transport-neutral read plans with stable IDs, targets, function names, arguments and expected values from the manifest. The plans verify existing read surfaces without adding protocol bytecode, including Core oracle/advanced/portfolio wiring, accounting scale, Advanced MM/liquidation/portfolio wiring, MM and lens back-references, standalone liquidation maintenance margin, and shared portfolio vault/policy/coordinator wiring.

Execute those reads with the DEX team's preferred RPC library, collect results by plan ID, then call `verifyDeploymentResults(plans, results)`. Address comparisons are case-insensitive and integer-like RPC results may be bigint, safe integers, or decimal strings.

A deployment pipeline should fail closed on any mismatch before publishing the manifest or starting the indexer/keepers.

## Market-maker packed encoding

`encodePackedQuoteUpdates` exactly matches `MarketMakerModule.batchReplaceQuotesPacked`:

- bits 0..95: lots;
- bits 96..111: tick;
- bit 112: side;
- bits 113..127: zero.

Updates must be strictly sorted by side/tick, matching the contract requirement.

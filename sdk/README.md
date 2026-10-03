# Order Book Integration SDK

Dependency-free TypeScript helpers for teams integrating the deployable CLOB.

The SDK deliberately does not own RPC transport or signing. It produces typed transaction plans that can be handed to viem, ethers, a custom relayer, or another Ethereum client.

## Included

- deployment manifest validation;
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

## Deployment manifests

Use `deployments/schema/v1.json` as the canonical machine-readable schema. A sample document is available at `deployments/example.json`.

Manifest values should be generated from the actual deployment inputs and verified on-chain before publication. Do not copy the example addresses into a real deployment.

## Market-maker packed encoding

`encodePackedQuoteUpdates` exactly matches `MarketMakerModule.batchReplaceQuotesPacked`:

- bits 0..95: lots;
- bits 96..111: tick;
- bit 112: side;
- bits 113..127: zero.

Updates must be strictly sorted by side/tick, matching the contract requirement.

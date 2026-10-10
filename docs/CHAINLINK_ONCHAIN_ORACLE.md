# Chainlink-backed canonical mark oracle (on-chain)

This integration uses deployed Solidity contracts, not an injected reader or relay-owned price value.

1. Deploy `ChainlinkPriceSource` with the correct **deployed, chain-specific Chainlink AggregatorV3 proxy**, its documented heartbeat, and either a real sequencer uptime feed plus a nonzero recovery grace period (for supported L2s) or address(0) and zero grace (for chains without a sequencer requirement).
2. Read `sourceScale()` from the deployed source (derived from the Chainlink feed's `decimals()`).
3. Deploy `SegmentTreeExtremaOracle` with a nonzero initial tick and a maxAge consistent with risk policy.
4. Deploy `ValidatedMarkOracleAdapter` using the deployed source and sink, with `sourceScale()`, the **market-specific tick conversion factor**, a maxAge no larger than the chosen source heartbeat and a zero confidence threshold (AggregatorV3 does **not** expose price-confidence).
5. Call `proposeUpdater(adapter)` from the sink owner and `acceptUpdater()` from the adapter address through an actual adapter-compatible authority arrangement. **Important:** the current adapter has no method to invoke `acceptUpdater()` directly. An adapter deployed alone cannot accept the sink's pending-updater role, so an end-to-end production deployment requires a safe updater-acceptance mechanism. Do not claim the stack deployable until this is fixed.
6. Before enabling trading, verify on-chain `updater()`, `source()`, `sourceScale()`, `markTick()`, `lastObservationTime()`, sequencer feed configuration, and expected chain IDs. Continue calling permissionless `publish()` as fresh Chainlink observations arrive. A reader call alone does not publish.

The source rejects zero/incomplete rounds, nonpositive prices, stale or future price observations and (when configured) down/recently recovered sequencers. It does not prove that a given feed address is the intended market: verify immutable addresses against the chain's official Chainlink feed directory. Do not wire this integration to real-money trading without independent audit and operational checks.

**Security limitations:** Chainlink AggregatorV3 does not provide an independent confidence interval; `confidence=0` means unavailable, not known-perfect. This source checks the price's freshness and the sequencer flag at reading time but does not provide an independent secondary oracle or deviation breaker. L1 deployments must only disable the sequencer check when appropriate.

The Ethereum mainnet fork integration test reads the **real** Chainlink ETH/USD proxy at `0x5f4eC3Df9CBD43714FE2740f5E3616155C5b8419` using `ETH_RPC`, and exercises the source-to-canonical-oracle flow. It does not use fake oracle implementations.

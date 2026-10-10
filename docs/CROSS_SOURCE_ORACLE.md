# Optional on-chain cross-source price corroboration

`CorroboratedPriceSource` is an immutable Solidity implementation of the existing `IExternalPriceSource` interface. It can sit **before** the existing `ValidatedMarkOracleAdapter`, without changing `OrderBookCore`, `IMarkOracle`, or the canonical observation-history contract.

Deploy with two independently reviewed on-chain feeds for **the same base asset, quote currency, and valuation convention**. Supply each feed's exact positive scale, maximum observation age, and allowable basis-point divergence. Both feeds must be deployed contracts. If either reverts, produces an invalid/future/stale price, or deviates from the reference beyond the immutable limit, `latestPrice()` reverts and no canonical observation is published. The primary's actual timestamp and confidence pass through unchanged.

**The guard does not prove oracle independence:** separate contract addresses may still reference one data provider or aggregator. Deployment teams must verify provenance, asset/quote identity, feed proxy configuration, supported chain, and required L2 sequencer checks. No source can bypass another's rejection, and there is no privileged mutable threshold or price override.

Deployment wiring:
- Primary feed -> `CorroboratedPriceSource.primary`
- Secondary independent source -> `CorroboratedPriceSource.referenceSource`
- `ValidatedMarkOracleAdapter.source` -> deployed `CorroboratedPriceSource`, with `sourceScale` equal to the **primary scale** and the market's required tick conversion and confidence policy
- `ValidatedMarkOracleAdapter.sink` -> `SegmentTreeExtremaOracle`; complete the two-step updater handoff using `acceptSinkUpdater()`

The live mainnet fork tests verify that different real Chainlink ETH/USD and BTC/USD feeds are rejected for disagreement, and that a single contract cannot satisfy both source-address parameters. **These are negative-path tests, not validation of any specific two-provider deployment.** A real-money market must separately establish a genuine independent same-market reference feed and test accepted normal-range updates, stale conditions, and incident recovery before launch.

No changes to Core bytecode, matching semantics, or the order book's oracle-selection interface.

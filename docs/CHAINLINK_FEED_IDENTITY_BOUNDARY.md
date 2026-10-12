# Chainlink feed identity is a deployment trust boundary

`ChainlinkPriceSource` verifies contract code at the configured feed address,
supported decimal precision, round completeness, positive answers, freshness,
and (when configured) L2 sequencer state. Its immutable `priceFeed` address
does **not** prove the feed corresponds to the intended base asset, quote
currency, network, or economic market.

Before deployment, independently verify the canonical feed/proxy address for
the exact chain, pair and denomination. Confirm feed decimals, expected
heartbeat, and whether the deployment chain requires an L2 sequencer uptime
feed and recovery grace period. Record the source of each address and the
verification date in the deployment record. Independently check the source
mapping of any corroborated reference feed; two contract addresses do not
prove independent price formation.

Adversarial regression: `test/ChainlinkFeedIdentityConfiguration.t.sol`
demonstrates that an unrelated feed with valid AggregatorV3 round data
passes syntactic validation. It does not demonstrate permissionless oracle
manipulation, and it cannot replace deployment-time identity verification.

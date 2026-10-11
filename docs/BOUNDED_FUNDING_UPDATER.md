# Optional Bounded Funding Updater

`BoundedFundingUpdater` is an **optional self-hosted authority wrapper** for a market's existing `OrderBookCore.setFundingIndex` entrypoint. It is vendor-agnostic and does not change the protocol funding formula. It is intended for operators who want on-chain protection against accidentally publishing an oversized index change or publishing too frequently.

## Deployment and authority

1. Finalize a documented funding formula, sampling source, observation freshness standard, and market accounting units.
2. Deploy `BoundedFundingUpdater(core, operator, minIntervalSeconds, maxAbsDeltaX18)`. The operator is the only publisher and the guard parameters are immutable.
3. From the Core **owner**, call `core.setFundingUpdater(address(boundedUpdater))`. This is a privileged owner action; it is not performed by the wrapper.
4. **Deploy and assign the wrapper before the first Core funding-index update (index = 0).** The wrapper tracks its own last published index but **cannot read Core's live funding index**. Do not rotate its authority away and back; the owner may bypass the bound.
5. Have the operator call `publish(nextIndex)` after the minimum interval. The guard rejects an absolute delta exceeding `maxAbsDeltaX18` and rejects shorter intervals.

## Deliberate limitations

- The bound is **per successful update**. An operator may publish repeatedly once each interval; choose both parameters conservatively. It does not verify the economic correctness of a small permitted update.
- The Core **owner can rotate the funding updater**. Governance key security, monitoring, timelocks, and incident policy remain mandatory.
- **Important trust limitation:** unexpected external index changes are **not detected**. The Core owner may assign another updater, publish a different index, and reassign this wrapper. The next publish is bounded relative to the wrapper's local index, not Core's current index. Operational monitoring and governance security must enforce continuous authority; do not represent this as a protocol-enforced governance bound.
- It does not itself fetch prices, attest oracle correctness, catch up elapsed funding, or ensure publishing liveness. Teams must build and verify these controls separately.
- No mandatory dual oracle and **no modifications to `OrderBookCore`**. The current Core does not expose a live index getter; this design intentionally avoids increasing Core runtime bytecode.

## Acceptance criteria

Verify positive/negative boundary values, unauthorized publishers, early updates, invalid constructor inputs, the authority-rotation bypass, failed Core calls, role rotation, and missed-update recovery in the team's staging chain. Independently review the wrapper and proposed operating bounds before committing real trader collateral.

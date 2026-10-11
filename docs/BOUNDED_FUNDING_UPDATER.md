# Optional Bounded Funding Updater

`BoundedFundingUpdater` is an **optional self-hosted authority wrapper** for a market's existing `OrderBookCore.setFundingIndex` entrypoint. It is vendor-agnostic and does not change the protocol funding formula. It is intended for operators who want on-chain protection against accidentally publishing an oversized index change or publishing too frequently.

## Deployment and authority

1. Finalize a documented funding formula, sampling source, observation freshness standard, and market accounting units.
2. Deploy `BoundedFundingUpdater(core, operator, minIntervalSeconds, maxAbsDeltaX18)`. The operator is the only publisher and the guard parameters are immutable.
3. From the Core **owner**, call `core.setFundingUpdater(address(boundedUpdater))`. This is a privileged owner action; it is not performed by the wrapper.
4. Ensure the Core index matches the wrapper's `lastIndexX18`. The wrapper refuses to overwrite a different index, including one changed through a governance authority rotation.
5. Have the operator call `publish(nextIndex)` after the minimum interval. The guard rejects an absolute delta exceeding `maxAbsDeltaX18` and rejects shorter intervals.

## Deliberate limitations

- The bound is **per successful update**. An operator may publish repeatedly once each interval; choose both parameters conservatively. It does not verify the economic correctness of a small permitted update.
- The Core **owner can rotate the funding updater**. Governance key security, monitoring, timelocks, and incident policy remain mandatory.
- It is intentionally **fail closed after an unexpected external index change**. An explicitly approved new wrapper deployment and owner handoff are required to recover authority.
- It does not itself fetch prices, attest oracle correctness, catch up elapsed funding, or ensure publishing liveness. Teams must build and verify these controls separately.
- No mandatory dual oracle, and no change to `OrderBookCore` runtime size.

## Acceptance criteria

Verify positive/negative boundary values, unauthorized publishers, early updates, invalid constructor inputs, foreign state mutation, failed Core calls, role rotation, and missed-update recovery in the team's staging chain. Independently review the wrapper and proposed operating bounds before committing real trader collateral.

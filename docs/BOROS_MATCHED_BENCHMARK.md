# Boros–pro-rata matched benchmark: source audit and evidence protocol

**Status: infrastructure for collecting and validating matched measurements, not a measured performance comparison.** No Boros fill gas numbers have been produced in this PR. Do not quote example inputs from the tests as benchmarks; their numbers are deliberately synthetic.

## Inspected Boros source

- [Pendle Boros public core at commit 78403bfe26d9a4c2cf8121726f4d6d9c1539009c](https://github.com/pendle-finance/boros-core-public/tree/78403bfe26d9a4c2cf8121726f4d6d9c1539009c)
- [Tick.sol](https://github.com/pendle-finance/boros-core-public/blob/78403bfe26d9a4c2cf8121726f4d6d9c1539009c/contracts/core/market/orderbook/Tick.sol): stores maker/order nodes with a 40-bit order index, subtree aggregate sums and match events. `matchPartialFillResult` locates the FIFO boundary using `__matchPartialInner`; `matchAllFillResult` advances the tick generation. This is **not** a naive “update every maker” loop, so assuming linear gas in maker count is unwarranted.
- [MarketOrderAndOtc.sol](https://github.com/pendle-finance/boros-core-public/blob/78403bfe26d9a4c2cf8121726f4d6d9c1539009c/contracts/core/market/MarketOrderAndOtc.sol) connects user order admission with account and market state. Do not compare an isolated tick library call with a full collateralized taker trade without labelling the different work.
- The public Boros package uses Solidity `^0.8.28` in the inspected tick library; this repository defaults to `0.8.24`. The benchmark must compile compatible versions under aligned optimizer and EVM settings or disclose that results are **not matched**.

Boros's public repository uses the BUSL-1.1 license. We link its source and inspect behavior; no Boros contract source has been copied into this repository.

## Benchmark fixture specification

For **each protocol**, collect actual transaction gas from equivalent taker order scenarios:

| Dimension | Matching condition |
| --- | --- |
| Same-tick maker count | 1, 8, 32, 64 makers; one price tick, 6,400 posted lots, 3,200 taker lots |
| Crossed tick count | 1, 2, 4, 8 ticks; 8 makers and 800 posted lots per tick; taker consumes **all** posted lots |
| Quote ordering | Same tick price priority and eligible maker mix; FIFO vs pro-rata outcomes are inherently different |
| Risk collateral | Configure enough margin for orders; disclose which protocol-specific admission/settlement work cannot be normalized |
| Gas accounting | Distinguish a whole transaction from isolated `gasleft()` around the matching function |
| EVM/compiler | Record chain/fork, EVM target, compiler version, optimizer profile, and cold/warm state |
| Contract revision | Pin full 40-digit commits for both repositories and actual deployment/test harness revisions |

Boros's rate instrument (implied APR, market maturity and oracle settlement) differs from our generic derivative tick. Equal integer “lots” are a *synthetic matching workload*, not proof of equivalent economic notional, margin or execution quality.

## Evidence file format

The CI-checked `script/compare_boros.mjs` consumes two JSON files. Both must be **genuine measurements** from independently run harnesses.

```json
{
  "protocol": "boros",
  "source": "pendle-finance/boros-core-public",
  "commit": "78403bfe26d9a4c2cf8121726f4d6d9c1539009c",
  "compiler": "0.8.28",
  "evm": "cancun",
  "optimizer": "100000",
  "rows": [
    {
      "makers": 8, "ticks": 2, "postedLots": 1600, "filledLots": 1600,
      "fillPolicy": "IOC", "gasEnvironment": "cold-transaction",
      "gasUsed": 0
    }
  ]
}
```

`gasUsed: 0` above is a **placeholder that the tool rejects**. Replace it with an actual measured positive integer and supply the corresponding order-book JSON. Do not commit fabricated benchmark results.

```sh
node --test test-js/compare-boros.test.mjs
node script/compare_boros.mjs /path/to/ours-measured.json /path/to/boros-measured.json
```

The script checks both source revisions, equivalent fixture keys, compiler/EVM/optimizer metadata, nonzero gas, missing or duplicate workloads and identical transaction cost conditions. It emits a side-by-side Markdown table only when its comparability preconditions pass. Since the published Boros core needs Solidity 0.8.28 and our default is 0.8.24, the comparator intentionally refuses mismatched compiler labels.

## Before a numerical claim

1. Build a runnable Boros MarketEntry full-transaction benchmark with its actual authorization, market state, order creation, funding and margin dependencies.
2. Run our **deployable modular** path under the corresponding admitted transaction path; do not rely only on the monolithic reference kernel.
3. Capture raw logs, Solidity versions, exact test scripts and source revisions. Include gas for order creation, taker trade, maker cancellation and deferred settlement in separate rows.
4. Confirm all workload keys match. If the products differ economically, say so clearly and publish both gas results without declaring equal economic efficiency.
5. Have an independent reviewer examine raw traces before publishing a competitive claim.

This PR provides the reproducibility contract and CI validation for evidence but does **not** complete steps 1–4. Production-readiness, audit coverage and price-time market dynamics must be assessed separately.

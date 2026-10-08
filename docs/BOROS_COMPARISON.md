# Boros CLOB parity and pro-rata differentiation: evidence matrix

This document separates measured local implementation behavior from Boros's documented mechanics. It does **not** claim equal workload gas performance until Boros's actual deployed implementation is benchmarked under a comparable compiler, EVM, tick depth, notional, collateral configuration and gas warm/cold state.

## Sources

- [Pendle: Boros order-book design](https://docs.pendle.finance/boros-dev/Mechanics/OrderBook) — rate-time matching and tick structures.
- [Pendle: Boros order-book user mechanics](https://docs.pendle.finance/boros-docs/boros-systems/orderbook) — order expiry, purging, mark/rate bounds and account-level limits.
- [Pendle: Margin mechanics](https://docs.pendle.finance/boros-dev/Mechanics/Margin) — collateral zones, initial/maintenance margin, health ratio and liquidation controls.
- [Pendle: Market reads](https://docs.pendle.finance/boros-dev/Contracts/Market) — lazy settlement and the distinction between settled and unsettled positions.
- Local sources: `src/ProRataOrderBook.sol`, `test/Gas.t.sol`, `test/ProRataOrderBook.t.sol`, `test/BorosParityWorkloads.t.sol`, and `docs/ARCHITECTURE.md`.

## Current comparison

| Dimension | Boros, as documented | This repository | Evidence / unresolved work |
| --- | --- | --- | --- |
| Market | Interest-rate swaps quoted in implied APR | General pro-rata leveraged order-book kernel | Different financial products; no apples-to-apples end-user cost comparison yet |
| Price priority | Best rate first | Best tick first | Both price prioritized |
| Same-price matching | FIFO/time priority, maker queue index | Pro-rata redeemable shares per aggregated tick | Material economic difference; not a FIFO implementation |
| Maker accounting | Lazy settlement | Maker share redemption and lazy fill/funding attribution | Both defer maker-specific work; no generic “only we use lazy settlement” claim |
| Tick structure | 65,536 discrete levels | 65,536 ticks, two-level bitmap | Different representations; requires normalized deployed benchmarks |
| Margin | Cross/isolated and maturity-aware exposure | Worst-case position envelope, reserved margin, collateral and liquidation | Instrument economics differ; broader stress tests required |
| Order maintenance | Purging, forced cancellation, maturity expiry | Maker cancellation, oracle bands, conditional expiry and liquidation | No feature parity claim for Boros's account controls |
| Settlement | Funding-rate oracle and maturity | Generic funding-index accounting and lazy maker settlement | Timing/precision/rounding parity not established |
| Deployment | Production Boros protocol | Experimental order-book stack | No audit or production readiness claim |

## Reproducible local gas workloads

Run from repository root:

```sh
forge test --match-contract BorosParityWorkloadsTest -vv
forge test --match-contract BorosParityWorkloadsTest --gas-report
forge test --match-test testFuzz_PartialFillCancellationConservesLots --fuzz-runs 5000
```

The suite emits `WorkloadGas` events with measured take gas. Events can be inspected using `-vvv` where supported by the Foundry installation. Make no cross-contract gas comparison until equivalent Boros calls run on the same EVM settings.

| Workload | Independent variable | Constant(s) | Expected invariant |
| --- | --- | --- | --- |
| Same-tick matching | 1, 8, 32, 64 makers | Tick 10,000; 6,400 total ask lots; 3,200 taker lots | Gas difference from the 1-maker case stays below existing 20,000-gas regression tolerance |
| Tick traversal | 1, 2, 4, 8 crossed ticks | Eight makers per tick; 100 lots per maker | Fully deplete each crossed tick (800 lots per tick); record growth with crossed ticks |
| Partial fill and cancel | Three makers, then one exits | 100 lots each; 90 initial taker fill | Each maker attributed 30; cancelling a 70-lot residual cannot remove others' 140 lots |
| Conservation property | Fuzz maker sizes, fill size | One tick, two makers | Total posted lots = executed + cancelled + executable remaining |
| Existing FOK/risk tests | Multiple ticks, margin and oracle bounds | See existing Foundry tests | FOK atomicity and reserved exposure assertions remain covered |

### Rounding, dust and economic risks

The matching pool stores **exact integer** `remainingLots`. Individual maker claim amounts use floor division of shares against remaining lots. Exact global liquidity conservation does **not** prove that all maker-level rounding residuals have been economically attributed fairly. In particular, adversarial tiny shares, frequent join/exit, old generations and early/late maker ordering warrant additional invariant and differential testing. Do not assume equal 1-lot allocation under integer rounding.

Liquidity incentives differ: pro-rata may motivate oversized displayed quotes or frequent cancellation, while FIFO prioritizes queue position. That is a market-design tradeoff, not an unqualified improvement.

## Risk and readiness gates

Current source contains collateral reservation, exposure envelopes, price-band execution controls, funding accounting and liquidation. The local suite measures the isolated reference `ProRataOrderBook` workload; the deployable modular contract path must also be benchmarked before publishing representative deployment gas.

Before claiming Boros parity, add a real Boros side-by-side harness using [Pendle's public Boros contracts](https://github.com/pendle-finance/boros-core-public), with matched order and pool configurations, optimizer settings, gas-metering environment, settlement modes and oracle/margin state. Record deployed bytecode, gas, revert conditions, maker cancellation cost, total transaction cost, and state evolution. Do not extrapolate Boros gas figures from its FIFO design alone.

## Acceptance and disclosure

New tests must pass the repository's full CI, Foundry fuzzing, size reports and strict EIP-170 check. Gas events describe only the local test fixture and are neither independent auditing nor an external performance benchmark. Published comparison claims must identify whether they come from Boros documentation, local instrumentation, or a completed matched implementation test.

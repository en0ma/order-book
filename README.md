# Fully On-Chain Pro-Rata Order Book

Experimental Solidity/Foundry implementation of a gas-oriented fully-on-chain order-book kernel.

The design keeps authoritative liquidity and matching entirely on-chain, but replaces FIFO within a price level with pro-rata allocation. That lets one taker fill an arbitrary number of makers at the same tick by updating aggregate tick state rather than every maker.

## Core properties

- 65,536 discrete ticks.
- Two-level occupancy bitmap for bounded best-price discovery.
- Exact integer lot accounting for executable liquidity.
- Pro-rata shares at the same tick.
- Lazy maker fill settlement.
- O(1) maker cancellation with respect to maker count.
- No linked-list tombstones or stale-order cleanup.
- IOC and FOK taker flow.
- Immediate aggressive-taker position and execution-notional accounting.
- Reduce-only execution that cannot cross through zero.
- Fully on-chain conditional trigger state with permissionless execution.
- Pairwise OCO conditional orders.
- True triggered-limit activation: take up to the limit, then rest the remainder.
- Minimum-fill and reduce-only minimum-fill aggressive execution.
- OTO child activation and TP/SL bracket composition with OCO exits.
- Extrema-oracle trailing stops without per-order watermark writes.
- One-slot packed risk envelope and one-slot packed account metadata.
- Exposure-envelope margin reservation.
- Oracle-bounded execution with per-pool risk ceilings.
- ERC-20 collateral custody.
- Pluggable mark-oracle adapter.
- Lazy funding attribution without maker writes during fills.
- Mark-to-market equity and configurable maintenance margin.
- Atomic liquidation with caller-supplied maker tick / conditional IDs.
- Active-order withdrawal safety.
- Foundry fuzz tests and explicit gas ceilings.
- GitHub Actions mainnet-fork test using real WETH custody.

## Conditional semantics

Conditional orders support two activation modes after the on-chain mark satisfies the trigger:

- bounded aggressive IOC/FOK execution for stop-market / take-profit-market behavior;
- triggered limit execution that first takes marketable liquidity up to the limit and then rests any unfilled quantity in the ordinary maker pool.

Both modes are fully on-chain and permissionlessly executable.

## Run

forge test -vvv

forge test --gas-report

forge snapshot

ETH_RPC=<mainnet-rpc> forge test --match-contract MainnetForkTest -vvv

See docs/ARCHITECTURE.md for the design, accounting model, liquidation flow, and current limitations.

This is a research prototype, not audited production code.


## Current bracket semantics

OTO children are dormant reduce-only conditionals. They activate only after the parent receives an actual aggressive fill and are resized to that filled quantity. Linking two children with OCO gives a take-profit / stop-loss bracket.

Maker fills from a triggered-limit remainder do not yet expand bracket children; that requires a separate lazy resize mechanism.

## Trailing stops

Trailing stops use an extrema-capable on-chain oracle. Each order stores an activation observation ID and trail distance rather than a mutable watermark.

At execution, the contract derives the high/low since activation from the oracle and verifies the retracement entirely on-chain. The included extrema oracle is a test mock; a production adapter needs an efficient on-chain range-extrema data structure.

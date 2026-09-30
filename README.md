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

Conditional orders currently execute as bounded aggressive IOC/FOK orders after the on-chain mark satisfies the trigger.

This supports stop-market / take-profit-market style behavior with an explicit worst execution tick. A true stop-limit order that activates into resting maker liquidity is intentionally not implemented yet.

## Run

forge test -vvv

forge test --gas-report

forge snapshot

ETH_RPC=<mainnet-rpc> forge test --match-contract MainnetForkTest -vvv

See docs/ARCHITECTURE.md for the design, accounting model, liquidation flow, and current limitations.

This is a research prototype, not audited production code.

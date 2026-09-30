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
- Exposure-envelope bookkeeping for future margin reservation.
- Foundry fuzz tests and explicit gas ceilings.
- GitHub Actions mainnet-fork test using the repository ETH_RPC secret.

## Run

forge test -vvv

forge test --gas-report

forge snapshot

ETH_RPC=<mainnet-rpc> forge test --match-contract MainnetForkTest -vvv

See docs/ARCHITECTURE.md for the design and current limitations.

This is a research prototype, not audited production code. It currently models order-book accounting and risk envelopes but does not custody or transfer assets.

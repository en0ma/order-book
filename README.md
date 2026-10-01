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
- Immutable taker-fee / maker-rebate accounting with lazy maker rebates.
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

Maker fills from a triggered-limit remainder now expand bracket children lazily when the maker settles or the module explicitly syncs the resting order. Matching still updates only aggregate tick state.

## Trailing stops

Trailing stops use an extrema-capable on-chain oracle. Each order stores an activation observation ID and trail distance rather than a mutable watermark.

At execution, the contract derives the high/low since activation from the oracle and verifies the retracement entirely on-chain. The repository now includes a bounded 4,096-observation segment-tree oracle with O(log N) append/query; the older mock remains test-only.


## Deployable architecture

The original `ProRataOrderBook` remains a research/reference monolith. It exceeds Ethereum's EIP-170 runtime bytecode limit and is not the production deployment shape.

The deployable path is split into:

- `OrderBookCore`: hot CLOB matching, maker shares, custody, risk envelopes, margin, funding, and narrow module hooks. Token/oracle/risk parameters are immutable deployment configuration.
- `AdvancedOrderModule`: reduce-only/min-fill wrappers, conditional orders, triggered limits, OCO/OTO, lazy bracket resizing, trailing stops, and authenticated forwarding to specialized modules.
- `MarketMakerModule`: managed maker-quote metadata plus atomic batch refresh/cancel policy.
- `LiquidationModule`: maintenance-margin policy and liquidation orchestration.
- `PortfolioMarginPolicy`: read-side cross-market risk aggregation with bounded hedge credits only for exposure guaranteed across each market's full risk envelope.
- `PortfolioLiquidationModule`: portfolio-wide health enforcement and atomic multi-market order cleanup / position reduction; it deliberately does not provide cross-market collateral transfer or admission credit.
- `PortfolioCollateralVault`: shared ERC-20 custody for portfolio deployments. Users retain ownership of deposited collateral; the configured controller may only lock/unlock balances for margin and cannot transfer user funds.
- `PortfolioAdmissionCoordinator`: sole risk-increasing gateway for portfolio-mode markets. It executes a market action and atomically synchronizes the shared vault lock against aggregate portfolio equity/requirement; insufficient collateral reverts the whole action.
- `OrderBookMath`: shared pure side/tick/share/risk arithmetic used by the deployable contracts.
- `SegmentTreeExtremaOracle`: bounded on-chain range high/low observations for trailing triggers.

Under the `size` Foundry profile (`optimizer_runs = 1`), the current measured runtime sizes are approximately 21,511 bytes for the core, 18,617 bytes for the advanced module, 4,434 bytes for the market-maker module, 4,001 bytes for the liquidation module, and 2,152 bytes for the extrema oracle.

CI enforces stricter project budgets than EIP-170: 22,000 bytes for the core, 19,500 bytes for the advanced module, 5,000 bytes each for the market-maker, liquidation, and portfolio-margin modules, 6,000 bytes for the portfolio-liquidation module, 4,000 bytes for the portfolio-collateral vault, 7,000 bytes for the portfolio-admission coordinator, and 4,000 bytes for the extrema oracle. New order-type or execution-policy logic should normally be added to specialized modules rather than expanding the matching core.


The advanced-order module is constructor-bound to the same oracle contract used by the core. Trailing-history verification therefore cannot silently use a different price source from execution.


## Market-maker quote refresh

Managed quotes live in MarketMakerModule while canonical liquidity remains in OrderBookCore.

A batch refresh:
- removes or reconciles only managed share slices;
- aggregates incremental exposure once per side;
- reserves margin once per side;
- preserves same-generation quote shares when the target is unchanged or larger;
- adds only the missing lots for increases;
- uses a full remove/rebuild only for exact decreases, avoiding ambiguous integer-share rounding.

Generation-aware core locks prevent a stale advanced/MM share reference from touching a fresh quote created at the same tick after pool rollover.

Batches require strict side/tick ordering with unique keys, which prevents ambiguous duplicate targets and creates a deterministic path for future delta-tick compression.

For latency-sensitive callers, MarketMakerModule also accepts a fixed-width packed format: each quote is one 16-byte record containing 96-bit lots, 16-bit tick, 1 side bit, and 15 reserved bits. The typed and packed entrypoints normalize into the same internal uint128 execution path.

For 16 quotes, calldata shrinks from 1,604 bytes with the typed ABI to 324 bytes packed, a 79.8% reduction. The packed and typed paths have essentially the same state-execution gas; the win is calldata size rather than fewer storage operations.

Dedicated gas-regression tests cover 1, 4, 8 and 16 managed levels. Current whole-test gas scales approximately 402k, 1.01m, 1.74m and 3.20m respectively, and the four-level batched replacement path is asserted to be cheaper than four separate replacement calls.


## Fees and rebates

The deployable core supports an immutable fee schedule fixed at market deployment:

- taker fee in basis points;
- maker rebate in basis points;
- maker rebate must not exceed the taker fee.

Taker fees are charged immediately from the taker's signed trading cashflow. The core reserves the net protocol fee at the same time.

Maker rebates remain lazy: no maker storage is touched during matching. When a maker later settles a fill, the rebate is derived from that maker's actual materialized notional at the quote tick and credited together with the trade cashflow.

The fee path does not call an external fee contract from matching and does not add a second maker write to the taker loop.

Integer rounding is conservative. The taker path reserves the maximum aggregate maker rebate, while individual maker rebates are floored when they materialize. Fuzz tests verify that credited rebates never exceed the amount reserved from the taker fee. Any rounding dust remains unallocated in core custody rather than being over-distributed.

Protocol fee withdrawal/distribution is not implemented yet; `protocolFeesAccrued` is accounting state only.

A recurring fee-enabled taker fill has a dedicated gas regression asserting less than 20,000 gas overhead versus the equivalent zero-fee fill after the protocol-fee storage slot has already been initialized.


### Portfolio admission boundary

Portfolio-mode cores are opt-in and may only be enabled before any local user collateral or pre-funded insurance exists. Direct risk-increasing `take` / `addLiquidity` paths and direct advanced-order reservation are disabled, and risk growth must pass through `PortfolioAdmissionCoordinator`. The portfolio policy counts the shared vault claim once and adds each market's mark-to-market value, preventing duplicate collateral counting across markets.

Fee-bearing portfolio cores are supported. Taker fees and lazy maker rebates remain in the core's existing fee-accounting path while the collateral tokens remain in shared custody. Protocol fees may be allocated to a market's insurance reserve without moving tokens. When a fully flattened portfolio has negative equity, configured portfolio liquidation can consume those insurance reserves and credit the corresponding shared-vault claim, preserving pooled custody while clearing bad debt.

The coordinator locks enough vault collateral so that the account's post-action portfolio equity remains above its aggregate requirement. Risk-reducing actions may leave excess collateral locked until `syncAccount` is called; this is conservative.

Once a vault controller is configured, direct vault withdrawals are disabled. Portfolio withdrawals must go through `PortfolioAdmissionCoordinator.withdraw`, which recomputes current settled cash equity and post-withdraw portfolio margin atomically. Realized trading/funding gains may therefore be withdrawn beyond the user's original deposit, while unrealized mark-to-market gains cannot. The vault records any withdrawal beyond gross deposits as a signed collateral claim offset by market cashflow, preserving pooled custody conservation.

Protocol-fee withdrawal as treasury revenue remains deliberately separate from user/insurance settlement; protocol fees can currently remain accrued or be allocated to portfolio insurance.

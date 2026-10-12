# Perpetual-CLOB engine boundary and implementation-gap register

**Scope:** reusable, self-hosted, fully on-chain pro-rata perpetual CLOB core and integration primitives. This is **not** a turnkey DEX, hosted exchange, endorsed market, or independent security certificate. Evidence refers to code on the reviewed main branch; any production deployment requires its own chain-specific review.

## The rule that decides where a feature belongs

**Engine obligation:** if failure can violate on-chain custody backing, account solvency, maker/taker allocations, on-chain authorization, funding settlement arithmetic, liquidation state transitions, or deterministic execution, its safety constraint belongs in reviewed protocol code. Keep matching gas proportional to price levels crossed rather than makers; prefer separate modules and view lenses under bytecode ceilings.

**Integrating DEX obligation:** if it requires choosing economic policy, assets/feeds/markets, infrastructure, human approvals, availability guarantees, strategy alpha, end-user UX, treasury recipients, or signers, the integrating DEX owns the choice and its operation. The engine may supply opt-in hooks, validations, and verifiable manifests; it must not quietly impose exchange-specific policy.

**Shared contract:** protocol supplies fail-closed authorization/accounting and sufficient events/interfaces; the DEX supplies independent live monitoring, data sources, deployment configuration and legally/operationally appropriate service guarantees.

## Status legend

- **Implemented:** source contains the mechanism; does not imply audited or deployment ready.
- **Partial:** relevant mechanisms exist, but an additional safety, integration or operational acceptance condition remains.
- **DEX-supplied:** deliberately not shipped or hosted here; integrating operators must provide it.
- **Roadmap:** optional new feature; do not confuse absence with an exploit.
- **Unverified:** needs a full source/control-flow audit and tests; do not claim it is absent.

## Boundary/ownership matrix

| ID | Area | Verified current mechanism | Remaining gap / exact boundary | Owner | Acceptance and evidence |
|---|---|---|---|---|---|
| FEE-01 | Fees and rebates | Core taker accrual, lazy maker rebates, packed fee and rebate reserves | Tiering and configurable recipient routing are absent; not needed to keep matching correct | DEX policy; opt-in protocol extension if widely needed | Rebate conservation fuzz, fee-rate parameter checks; `OrderBookCore.sol`, `docs/ARCHITECTURE.md` |
| FEE-02 | Fee to insurance allocation | **Implemented** `allocateProtocolFeesToInsurance(amount)`, owner-only; reserve reclassification, no ERC-20 payout | Docs previously claimed allocation missing; explicit policy for how much to allocate belongs to DEX | Engine protects authorization/invariants; DEX sets policy | Authorized allocation never exceeds accrued fees or changes physical custody; unauthorized calls revert |
| FEE-03 | Protocol revenue payout | `protocolFeesAccrued()` provides a reserve view; liquidation rewards can debit this reserve | No verified general treasury withdrawal / recipient routing. Accrued != guaranteed distributable surplus | Engine must prove solvency and payout bound before optional feature; DEX chooses recipient/governance | No payout until claim reconciliation with lazy rebates, standalone and portfolio liabilities; full token/reentrancy matrix and external review |
| FUND-01 | Funding settlement | Core signed funding index and lazy maker funding accounting | Rate derivation, reference venues, sampling, publication cadence, operator liveness, missed periods | DEX-supplied economic policy/operator | Document independent rate specification and replay/catch-up drills; `docs/BOUNDED_FUNDING_UPDATER.md` |
| FUND-02 | Funding authority | `setFundingUpdater`, optional bounded updater | Core owner can bypass wrapper by rotating authority; wrapper does not prove economically sound rates | Engine role checks; DEX multisig and monitoring | Rotation alert, unauthorized mutation tests, bounded wrapper review, compromised signer tabletop |
| ORCL-01 | Price validity | On-chain adapters, freshness/round/scale/deviation checks and bounded tick normalization | Feed address/asset/quote identity and actual independent sources are not proved by returned data | Engine validates format/guards; DEX selects/attests feeds | Network, feed proxy, asset pair, heartbeat, decimals, source independence, sequencer policy recorded and tested |
| ORCL-02 | Oracle availability | On-chain execution bands, selected adapter trust boundary | Publisher liveness, RPC availability, failover, outlier incident response | DEX operations; engine fail-closed risk controls | Stale/deviation/future/zero prices; risk-off/withdrawal/cancellation behavior verified on target chain |
| LIQ-01 | Liquidation accounting | Maintenance check, order cleanup, partial IOC close, terminal insurance cover and bounded rewards | No guaranteed book counterparty or automatic successful close | Engine safety; DEX provides liquidator, opposite liquidity | Partial/zero-fill/terminal cases, no phantom closes/rewards, preserve residual bad debt |
| LIQ-02 | Liquidation discovery | Caller-supplied quote/conditional/trailing/strategy identifiers | A liquidator needs complete and fresh active-order discovery; cannot infer from a simplistic market snapshot | DEX indexer/keepers, assisted by engine lens/events | Reorg-safe completeness checks, adversarial missing-ID and gas-limit tests |
| CUST-01 | Standalone collateral | Exact ERC-20 inbound accounting, guarded withdrawals; insurance and fee reserve state | Solvency over all claims, abnormal ERC-20 callbacks, realized/unrealized PnL under insolvency | Engine invariants; DEX selects collateral | Exhaustive conservation/reentrancy tests, reserve backing and negative-equity cases |
| CUST-02 | Portfolio collateral | Vault/coordinator, market admission and portfolio liquidation | Cross-market liabilities, fee/rebate custody, hedge-credit economic stress and market-set migration | Engine must not mint claims; DEX owns risk policy | Multi-market invariant with custody liabilities before any treasury fee payout |
| OPS-01 | Indexer | Reference event replay, read model, integration lens and recovery components | Full deployment ABI decoding, production persistence, deep reorg procedures, RPC trust | DEX-supplied operations | Reconcile canonical events against direct chain state, loss/reorg recovery, durable head and snapshots |
| OPS-02 | HTTP/API | Optional HTTP adapter, auth/readiness and pagination mechanisms | Hosting, TLS, edge controls, deployment authorization, rate limiting, public API uptime | DEX-supplied services | Enable fail-closed diagnostics and safe-head lag gating; inject stale/reorg/failure conditions |
| OPS-03 | Transaction operations | SDK transaction plans, operator scheduling primitives | Signing keys, relay, nonce/replacement policy, keepers, rate limits and market makers | DEX-supplied services | Replay/reorg/idempotency tests; isolated signers; no custody key in indexer |
| GOV-01 | Emergency risk controls | Owner risk-increase pause and restricted updater risk-off | Generic guardian/incident manager not shipped; pause does not guarantee forced liquidation or market settlement | Engine safety boundary; DEX Safe/timelock/runbook | Permission matrix for each action under pause, unauthorized unpause prevention, staged incidents |
| MKT-01 | Market creation | Per-market standalone deployments and constructor-defined portfolio sets | No generic runtime listToken, dynamic portfolio addMarket, forced market-delete | Deliberate design; DEX deploys/registries/migrates | Migration playbooks and liabilities reconciled on retirement; do not promise forced close without liquidity |
| EXEC-01 | Advanced strategies | Post-only, iceberg, TWAP-style slices, pegged maker orders | Volume participation/VWAP and richer optional composition | Optional roadmap; DEX may implement off-chain | Keep engine gas invariant; do not precommit unavailable future slice margin |
| PRODUCT-01 | End-user exchange | SDK, manifest, event/read-model primitives | No hosted frontend, API, actual market-making capital, customer support | DEX-supplied product | Document minimum production integrations and clear truth-in-marketing |
| ASSURE-01 | Release approval | Foundry fuzz, fork, gas and size CI, internal review register | Independent audit and approval of exact deployment, dependencies and live key/oracle configuration | Independent auditors + DEX release owner | Signed external audit report, remediated findings, deploy bytecode attestation, incident drill |

## Non-negotiable engine invariants for future feature PRs

1. **Accounting conservation:** token custody backs aggregate user claims and booked reserves under the actual collateral model; never confuse accumulated fees with withdrawable surplus.
2. **Authorization:** external callers cannot invoke reserve-spending Core or gateway hooks; owner authority is explicit, narrowly scoped, and tested through rotations.
3. **Settlement correctness:** lazy maker settlements, funding, rebates, generation rollover and rounding dust must not mint additional executable lots or unbacked claims.
4. **Liquidation correctness:** no cover before terminal closure; partial and zero fills cannot extract phantom rewards; insurance cannot cover more than actual terminal debt or existing reserve.
5. **Oracle trust:** price-scale validation cannot establish asset identity or source independence; these remain externally attested.
6. **EVM budgets:** match cost remains price-level-bound; reject implementations that introduce per-maker writes on taker path or exceed default-profile size/gas ceilings.
7. **Portfolio isolation:** standalone cash and portfolio vault claims must not be accidentally commingled or twice counted, including on protocol fee allocation.

## PR and release sequencing: broad work packages

**A. Accounting safety and fee lifecycle (protocol-owned, highest priority).** Define a complete state-machine invariant spanning fees, maker rebate reserve, insurance allocation and withdrawals; test unauthorized and owner-authorized allocation, bad debt, rounding, zero/edge amounts, callback tokens and partial liquidations. Design optional surplus payout only after both standalone and portfolio accounting prove distributable backing. Do not merge an unproved payout function.

**B. Privileged boundary and risk-off behavior (protocol-owned).** Audit every Core/Advanced/Liquidation/Portfolio authorization transition and pause/risk-reduction lifecycle, including the configured gateway, funding rotation, asset callbacks and recoverability. Preserve existing design modularity.

**C. Cross-market conservation and insolvency (protocol-owned).** Stateful multi-market portfolio property tests with positive/negative realized PnL, funding, insurance, bad-debt realization, hedge credit and maker dust. Require exact shared vault custody backing; no dependence on off-chain indexer truth.

**D. Oracle and funding integration contracts (shared).** No bespoke venue rate formula or privileged exchange oracle policy in Core. Provide transport-neutral validation, test fixtures and deployment attestation specification; DEX supplies real providers, rate algorithm, publishing infrastructure and monitoring.

**E. Liquidation operation correctness (shared).** Engine emits authoritative lifecycle and supports safe cleanup; DEX supplies reorg-safe enumerators, keepers, market makers and operational SLOs. Test missing IDs, stale inventories and insufficient liquidity without pretending guaranteed liquidations.

**F. Integration readiness and truth-in-docs (DEX-supplied).** SDK schemas, event/read-model reconciliation requirements, example fail-closed config, release checklist, migration and incident drills. No embedded hosted API, database, signer, governance Safe or exchange frontend.

**G. Optional commercial/execution features (not release blockers).** VWAP/participation, fee tiers, advanced UI, dynamic market listing should remain optional and separate from core custody and execution correctness unless a concrete safety requirement justifies Core modifications.

## Handoff checklist for a integrating perp DEX

- Choose target chain, collateral token, lot accounting scale, margin and fee economics, market identities, portfolio structure and trusted oracle sources.
- Own governance Safe/timelock, role rotation, emergency/risk-off decisions and independent authority-change alerts.
- Run authenticated RPC, durable indexer, read-model/API, keepers, liquidation bots, funding calculation/publishing and market-making liquidity.
- Verify all runtime bytecode/ownership/modules against approved deployment spec and signers; never reuse placeholder example addresses.
- Monitor price freshness, indexer lag, funding changes, order inventory completeness, liquidation failure rate, insurance reserves, custody and claim solvency.
- Arrange independent contract/economic audit of the exact deployable configuration and stage a live-chain pilot before unrestricted user funds.

## Evidence and limits

Primary source locations: `src/deployable/OrderBookCore.sol`, `src/deployable/LiquidationModule.sol`, `docs/ARCHITECTURE.md`, `docs/FEATURE_CATALOG.md`, `docs/ACCOUNTING_GATES.md`, `docs/BOUNDED_FUNDING_UPDATER.md`, `docs/NETWORK_DEPLOYMENT.md`, `docs/GOVERNANCE_AND_KEYS.md`, `docs/EVM_EXPLOIT_AUDIT.md`, `operator/RPC_ADAPTER.md`, `operator/HTTP_RUNTIME.md`, `operator/READINESS.md`.

This register documents verified interfaces and documented trust boundaries, **not** exhaustive proof of absence, a claim of active exploitability, or permission to deploy unaudited funds. Each implementation work package needs source-level review, explicit acceptance tests, exact-head CI, and independent deployment audit.

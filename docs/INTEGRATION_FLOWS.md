# System Perp DEX Integration: Concepts and Service Flows

This guide shows how a team integrates the deployable contracts with its own perpetual DEX. The on-chain state is authoritative. An indexer makes it easy to read. A keeper submits transactions when a task is due. Neither service owns matching or collateral.

For full procedures, read the [deployment team handbook](TEAM_HANDBOOK.md), [system architecture](SYSTEM_ARCHITECTURE.md), [operator runbook](OPERATOR_RUNBOOK.md), and [deployment guide](SELF_HOSTED_DEPLOYMENT.md).

> **Integration guides:** [List a market](MARKET_LISTING.md) · [Parameter reference](PARAMETER_REFERENCE.md) · [Governance and keys](GOVERNANCE_AND_KEYS.md).

![DEX integration architecture](assets/diagrams/dex-integration.svg)

[Edit the architecture diagram](assets/diagrams/source/dex-integration.drawio).

## 1. What a deployment DEX team receives and builds

```mermaid
flowchart TB
    subgraph TEAM["DEX team: deployment services to build and operate"]
      APP["Web / mobile trading UI"]
      API["Backend API / WebSocket"]
      DB["Database / read cache"]
      RPC["RPC connections / transaction submission"]
      SIGNAL["Trading strategy and market makers"]
      ENGINE["Operator service / job dispatcher"]
      WALLET["User wallets and keeper signers"]
      ALERT["Monitoring, alerts and incident response"]
    end
    subgraph REPO["Repository: reusable deployment components"]
      SDK["TypeScript SDK: transaction plans and verification"]
      IDX["Reference indexer: event replay and reorg rollback"]
      PLAN["Operator library: sync and keeper task planning"]
      CLOB["OrderBookCore: order book, risk and collateral"]
      ADV["Advanced orders and execution strategies"]
      MM["MarketMakerModule"]
      LIQ["Liquidation and risk policy"]
      PORT["Optional portfolio vault / coordinator / policy"]
    end
    subgraph EXTERNAL["Team-selected deployment dependencies"]
      CHAIN["EVM chain"]
      TOKEN["Collateral token"]
      ORACLE["Mark / extrema oracle"]
    end
    APP --> API
    APP --> WALLET
    API --> SDK
    SDK --> WALLET
    WALLET --> RPC
    SIGNAL --> SDK
    SIGNAL --> RPC
    RPC --> CHAIN
    ENGINE --> PLAN
    PLAN --> IDX
    IDX --> DB
    API --> DB
    ENGINE --> RPC
    CHAIN --- CLOB
    CHAIN --- ADV
    CHAIN --- MM
    CHAIN --- LIQ
    CHAIN --- PORT
    CLOB --> TOKEN
    CLOB --> ORACLE
    ENGINE --> ALERT
```

**System ownership rule:** The repository contains logic and libraries. The team must host the public API, RPC adapters, database, market-making strategy, transaction signers, monitoring and incident response.

## 2. How a deployment trade reaches the chain

```mermaid
sequenceDiagram
    actor User as Trader
    participant UI as DEX frontend
    participant API as DEX backend
    participant SDK as Order Book SDK
    participant RPC as Transaction transport
    participant Core as On-chain Core
    participant Index as System indexer
    User->>UI: Select market and order
    UI->>API: Read indicative book and account state
    API->>Index: Query indexed view
    Index-->>API: Book and position projection
    API-->>UI: Display state and quote
    User->>UI: Confirm trade
    UI->>SDK: Build contract call plan
    SDK-->>UI: Target, method and arguments
    UI->>RPC: Simulate and submit signed transaction
    RPC->>Core: Execute taker or maker call
    Core-->>RPC: Receipt and canonical events
    RPC-->>UI: Transaction status
    Core-->>Index: Events observed via chain RPC
    Index-->>API: Updated canonical projection
    API-->>UI: Refresh UI after confirmations
```

**System safety rule:** Never treat the indexer's quote as proof that a trade can execute. Simulate against current contract state before signing when practical. Price movement and transaction ordering can change the result.

## 3. How a deployment indexer reconstructs state

```mermaid
flowchart TD
    A["Deployment manifest: chain, addresses, start block"] --> B["RPC block and log reader"]
    B --> C["Decode protocol events into normalized records"]
    C --> D{"Canonical parent hash matches?"}
    D -- Yes --> E["Apply ordered events"]
    D -- No --> F["Find retained common ancestor"]
    F --> G["Rollback indexed state"]
    G --> B
    E --> H["Persist state and block-hash checkpoint"]
    H --> I["Book depth, accounts, order registry and maker inventory projections"]
    I --> J["Trading API, monitoring and keeper planner"]
    J --> K["Direct on-chain verification when decisions affect funds"]
```

The deployment indexer must handle restarts, duplicate logs, finality delay and bounded reorgs. It must not delete a quote from the liquidation registry based on an unconfirmed event.

## 4. How deployment keepers power advanced orders

```mermaid
sequenceDiagram
    participant Chain as EVM contracts and oracle
    participant Index as System indexer
    participant Planner as Reference operator planner
    participant Keeper as Team keeper service
    participant RPC as Team RPC and signer
    Index->>Chain: Read canonical logs and marks
    Chain-->>Index: Orders, triggers and relevant state
    Index->>Planner: Canonical index state
    Planner-->>Keeper: Eligible conditional, expiry or strategy tasks
    Keeper->>Chain: Verify current on-chain eligibility
    Keeper->>RPC: Simulate transaction
    alt Simulation valid
       RPC->>Chain: Submit signed keeper transaction
       Chain-->>Index: Execution / expiry / update events
    else Stale task or unavailable conditions
       Keeper->>Keeper: Record failure and retry policy
    end
```

**Concept:** A conditional order is stored on-chain, but the EVM does not wake up by itself. A keeper calls the execution function when a condition is satisfied. The contract still checks eligibility. Keepers must remain available for timely execution.

## 5. How deployment makers maintain and settle quotes

```mermaid
flowchart LR
    A["Market-maker strategy: desired spreads and inventory"] --> B["Read current risk, positions and fills"]
    B --> C["Create quote batch using SDK"]
    C --> D["Simulate risk and post-only checks"]
    D --> E["Sign and submit quote transaction"]
    E --> F["MarketMakerModule / Core"]
    F --> G["Maker receives pool shares"]
    G --> H["Taker trades against aggregate tick"]
    H --> I["Maker reconciles lazy fills and funding"]
    I --> B
```

At the same tick, makers share fills pro rata. Taker execution changes aggregate tick state; it does not write to every maker account. The maker's deployment inventory model must materialize pending fills before it makes risk decisions.

## 6. How deployment liquidation operators coordinate cleanup

```mermaid
sequenceDiagram
    participant Risk as Risk monitor
    participant Registry as Canonical order registry
    participant Bot as Liquidator
    participant Core as Core and advanced orders
    participant Book as Opposing CLOB liquidity
    Risk->>Core: Read current equity and maintenance requirement
    Risk-->>Bot: Candidate account
    Bot->>Registry: Get all resting quotes and advanced/strategy IDs
    Registry-->>Bot: Candidate cleanup list
    Bot->>Core: Recheck active order counts and simulate
    alt Cleanup state incomplete
       Bot->>Registry: Rebuild and reconcile registry
       Bot->>Bot: Alert and defer
    else Cleanup is complete
       Bot->>Core: Submit cleanup and liquidation transaction
       Core->>Book: Execute available reduce-only closeout
       Book-->>Core: Actual filled lots
       Core-->>Bot: Residual position, debt and events
       Bot->>Bot: Retry or escalate any remaining exposure
    end
```

**System warning:** If no opposing liquidity exists, liquidation cannot invent fills. A deployment liquidator must track residual positions, insurance reserves and unfilled closeout attempts.

## 7. Standalone and portfolio deployment deployment choices

```mermaid
flowchart TD
    TEAM["Team selects deployment risk mode"] --> CHOICE{"Shared collateral across markets?"}
    CHOICE -- No --> STAND["Standalone: one Core and collateral ledger per market"]
    CHOICE -- Yes --> PORT["Portfolio: approved shared vault + coordinator + policy"]
    STAND --> MARKETS["Configure mark oracle, fees, funding, modules and keepers"]
    PORT --> GUARD["Configure and validate cross-market admission and risk policy"]
    GUARD --> MARKETS
    MARKETS --> VERIFY["Verify runtime bytecode, addresses and role assignment"]
    VERIFY --> PILOT["Stress test, audit remediation and controlled deployment pilot"]
```

Portfolio deployment requires additional review of correlated market moves, funding and shared collateral. A deployment team should qualify standalone operation first.

## 8. How deployment monitoring supports incident response

```mermaid
flowchart TD
    METRICS["RPC health, chain finality, index lag, keeper queues, oracle age, funding events, liquidation residuals"] --> CHECK{"Risk threshold exceeded?"}
    CHECK -- No --> RUN["Continue guarded deployment operation"]
    CHECK -- Yes --> PAGE["Page on-call operator and risk owner"]
    PAGE --> EVAL["Verify canonical on-chain state and deployment manifest"]
    EVAL --> DECIDE{"Risk increase is unsafe?"}
    DECIDE -- Yes --> PAUSE["Authorized risk-off action; halt affected service dispatch"]
    DECIDE -- No --> REPAIR["Repair service and replay canonical history"]
    PAUSE --> REPAIR
    REPAIR --> RECON["Reconcile custody, orders, funding and positions"]
    RECON --> APPROVE["Authorized recovery and incident approval"]
```

## 9. System integration checklist

1. Assign owners for contracts, risk, oracle, market makers, indexers, keepers and keys.
2. Select standalone or portfolio deployment mode. Approve the associated margin model.
3. Build a versioned deployment spec and validate the actual bytecode and addresses.
4. Build a frontend and transaction transport around SDK plans.
5. Implement durable canonical event indexing and independent state reconciliation.
6. Implement keeper execution with live reads, transaction simulation and failure recovery.
7. Connect deployment makers with inventory accounting and signed quote workflows.
8. Run liquidation rehearsals with missing orders, missing liquidity and keeper outages.
9. Test funding rotation alerts, oracle faults, reorgs and emergency risk-off behavior.
10. Obtain an external security audit and deployment-specific release approval before unrestricted deployment funds.

The repository supplies no hosted deployment operator and does not guarantee deployment liquidity.

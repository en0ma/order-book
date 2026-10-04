# Self-Hosted Deployment

This repository is intended to be forked or cloned by DeFi teams that operate their own DEX deployments.

Each team is expected to:

- choose its own collateral asset and oracle;
- deploy its own market contracts;
- list its own markets/assets;
- own protocol administration through its own Safe, timelock, or governance contract;
- run its own indexer, keepers, liquidators, market-making infrastructure, RPC stack and frontend/backend;
- publish its own deployment manifest for clients and operators.

The repository does not assume a hosted control plane or shared production deployment.

## Standalone market bootstrap

The first reference deployment script is:

`script/DeployStandalone.s.sol:DeployStandalone`

It deploys and wires:

- `OrderBookCore`;
- `AdvancedOrderModule`;
- `MarketMakerModule`;
- `LiquidationModule`;
- `IntegrationLens`.

The script configures the accounting scale, advanced module, market-maker module, liquidation module and liquidator reward before handing protocol administration to `PROTOCOL_ADMIN`.

`PROTOCOL_ADMIN` should normally be the DEX team's Safe, timelock or governance executor rather than the funded broadcast key.

The script assigns the Core funding-updater role to a separate `FUNDING_UPDATER` address, so routine funding operations do not need to use the governance admin and the deployer key is not left with an operational privilege after bootstrap.

### Required environment

```bash
export PROTOCOL_ADMIN=0x...
export FUNDING_UPDATER=0x...
export COLLATERAL_TOKEN=0x...
export MARK_ORACLE=0x...

export EXECUTION_BAND_TICKS=40
export INITIAL_MARGIN_BPS=1000
export MAINTENANCE_MARGIN_BPS=500
export TAKER_FEE_BPS=5
export MAKER_REBATE_BPS=2
export LIQUIDATOR_REWARD_BPS=25
export COLLATERAL_UNITS_PER_LOT_TICK=1000
```

`MARK_ORACLE` must satisfy the Core mark-price interface and the extrema interface required by `AdvancedOrderModule` for trailing orders. A deployment may use the repository's canonical oracle stack or another compatible implementation.

### Broadcast

Use the normal Foundry broadcaster for the target chain:

```bash
forge script script/DeployStandalone.s.sol:DeployStandalone \
  --rpc-url "$RPC_URL" \
  --broadcast \
  -vvvv
```

The funded broadcaster performs deployment and one-time wiring. The configured protocol admin receives the long-lived administrative authority before the script finishes, while the configured funding updater receives only the Core funding-update role.

Before a production broadcast, run the script without `--broadcast` against the target RPC and verify every address and parameter.

## Market listing model

A DEX team chooses the markets it wants to offer. Each market has its own Core and associated market modules and may use market-specific oracle/risk/fee parameters.

A team can therefore deploy, for example, ETH-PERP, BTC-PERP and a project-specific market without changing the matching engine. The DEX's own deployment manifest gives its SDK, backend, indexer and keepers the authoritative address/configuration set.

The engine does not maintain a global registry controlled by this repository.

## Administration

The configurable protocol contracts support ownership handoff so a deployment does not need to retain a deployer hot key.

The standalone bootstrap transfers:

- `OrderBookCore` administration;
- `AdvancedOrderModule` administration;
- `LiquidationModule` administration;
- Core funding-update authority to the separately configured funding operator.

The portfolio policy and collateral vault also support ownership handoff for portfolio deployments.

Ownership transfer does not affect matching-path execution.

## After deployment

A deployment team should:

1. verify deployed bytecode and constructor parameters;
2. verify the module wiring and protocol-admin addresses;
3. publish a deployment manifest matching `deployments/schema/v1.json`;
4. initialize and validate oracle operations;
5. start its own indexer from the deployment block;
6. start keeper/liquidator/MM services against that manifest;
7. run smoke trades and recovery checks before enabling public access;
8. complete deployment-specific security and operational review.

The example manifest under `deployments/example.json` is not a production deployment and its addresses must not be reused.

## Portfolio deployments

Portfolio mode uses the same self-hosted model: the DEX team deploys and operates all markets, shared collateral custody, margin policy, admission coordination and liquidation infrastructure.

The portfolio policy and shared collateral vault now support explicit ownership transfer to the team's protocol admin. A reference multi-market portfolio bootstrap script is the next deployment-tooling layer; until that script lands, portfolio deployments should follow the tested constructor/configuration ordering in the portfolio test suite rather than inventing a different wiring sequence.

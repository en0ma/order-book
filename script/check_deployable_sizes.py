#!/usr/bin/env python3
import json
from pathlib import Path

LIMIT = 24_576
TARGETS = [
    ("OrderBookCore", Path("out/OrderBookCore.sol/OrderBookCore.json"), 22_000),
    ("AdvancedOrderModule", Path("out/AdvancedOrderModule.sol/AdvancedOrderModule.json"), 19_500),
    ("MarketMakerModule", Path("out/MarketMakerModule.sol/MarketMakerModule.json"), 5_000),
    ("LiquidationModule", Path("out/LiquidationModule.sol/LiquidationModule.json"), 5_000),
    ("LiquidationPolicy", Path("out/LiquidationPolicy.sol/LiquidationPolicy.json"), 3_000),
    ("PortfolioMarginPolicy", Path("out/PortfolioMarginPolicy.sol/PortfolioMarginPolicy.json"), 5_000),
    ("PortfolioLiquidationModule", Path("out/PortfolioLiquidationModule.sol/PortfolioLiquidationModule.json"), 6_000),
    ("PortfolioCollateralVault", Path("out/PortfolioCollateralVault.sol/PortfolioCollateralVault.json"), 4_000),
    ("SegmentTreeExtremaOracle", Path("out/SegmentTreeExtremaOracle.sol/SegmentTreeExtremaOracle.json"), 4_000),
]

failed = False

for name, path, budget in TARGETS:
    if not path.exists():
        raise SystemExit(f"missing artifact: {path}")

    artifact = json.loads(path.read_text())
    deployed = artifact["deployedBytecode"]["object"]
    if deployed.startswith("0x"):
        deployed = deployed[2:]

    size = len(deployed) // 2
    eip_margin = LIMIT - size
    budget_margin = budget - size
    status = "OK" if budget_margin >= 0 else "BUDGET_EXCEEDED"
    print(
        f"{name}: runtime={size}B "
        f"budget={budget}B budget_margin={budget_margin}B "
        f"eip170_margin={eip_margin}B status={status}"
    )

    if size > LIMIT or size > budget:
        failed = True

if failed:
    raise SystemExit("deployable runtime exceeds project bytecode budget or EIP-170")

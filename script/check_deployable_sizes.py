#!/usr/bin/env python3
import json
from pathlib import Path

LIMIT = 24_576
TARGETS = [
    ("OrderBookCore", Path("out/OrderBookCore.sol/OrderBookCore.json")),
    ("AdvancedOrderModule", Path("out/AdvancedOrderModule.sol/AdvancedOrderModule.json")),
    ("SegmentTreeExtremaOracle", Path("out/SegmentTreeExtremaOracle.sol/SegmentTreeExtremaOracle.json")),
]

failed = False

for name, path in TARGETS:
    if not path.exists():
        raise SystemExit(f"missing artifact: {path}")

    artifact = json.loads(path.read_text())
    deployed = artifact["deployedBytecode"]["object"]
    if deployed.startswith("0x"):
        deployed = deployed[2:]

    size = len(deployed) // 2
    margin = LIMIT - size
    status = "OK" if margin >= 0 else "TOO_LARGE"
    print(f"{name}: runtime={size}B margin={margin}B status={status}")

    if size > LIMIT:
        failed = True

if failed:
    raise SystemExit("deployable runtime exceeds EIP-170")

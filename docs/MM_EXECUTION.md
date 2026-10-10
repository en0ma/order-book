# Canonical quote execution coordinator

The coordinator uses a canonical managed-quote snapshot before simulation and again immediately after simulation. It rejects changes to the planned delta, applies shared risk-off safety checks, and permits pure cancel operations when price or sequencer feeds are unavailable. Integrate actual `MarketMakerModule` packed calldata, authenticated signer/nonce management and canonical receipt tracking through `MakerExecutionAdapter`. The coordinator does **not** post continuously, verify fills after mining, or implement profitable inventory-aware quoting.

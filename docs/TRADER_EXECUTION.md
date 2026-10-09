# Trader transaction lifecycle

The transport-neutral `trader-service` checks preflight oracle health, simulates and rechecks before submission. It deduplicates concurrent requests by idempotency key and reconciles chain receipts. This is **process-local** coordination. Production deployments need durable idempotency, signed authorization, custody/nonce controls, mempool replacement and canonical confirmation/reorg handling. This is not a hosted trade API or a wallet.

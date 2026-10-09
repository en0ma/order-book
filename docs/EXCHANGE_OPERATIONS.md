# Exchange health and incident policy

Aggregate canonical lag, RPC agreement, oracle age, sequencer health, keeper signer and queue metrics using the exchange-health evaluator. Failing readiness signals are **preflight decisions**; deployment teams must bind real observed metrics and their monitoring, on-call alerts and admission controls. Queue warnings alone do not halt trading. Incidents require explicit acknowledgement and restored readiness before clearance.

## Before real-money deployment

Run a recovery drill with a reorged checkpoint, RPC witness split, stale oracle, failed signer, duplicate keeper tasks, replay after downtime, and market-maker kill switch. Configure durable job state, a signer with restricted authority, multi-party guardian procedures, alert delivery, and external security reviews. This package is not a hosted exchange, transaction queue, streaming backend, or audited production monitoring service.

# OPS-02/03 — production API and transaction operations interface

**Status:** BACKLOG SPECIFICATION ONLY — no implementation or release approval.

**Owner:** DEX + reference

## Scope

Define reference optional interfaces for authenticated RPC, durable checkpoints, API readiness and keeper idempotency, nonce replacement and reorg recovery.

## Acceptance criteria

Adversarial stale/failure/reorg, replay and duplicate-submission tests; no hosted API, custody signer or relay shipped.

## Existing work / dependencies

Existing operator components.

## Merge gate

Leave as draft until replaced with real code, targeted adverse and integration tests, exact-head fully successful CI, zero unresolved reviews and appropriate independent custody/economic audits. DEX-hosted capabilities are not embedded in the reusable CLOB engine.

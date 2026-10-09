# Durable trader submission journal

A single-process atomic JSON journal stores reserved, broadcast and terminal transaction identities across crashes. A reserved record with no tx hash is **ambiguous** after a crash and must be reconciled against signer nonce and chain/mempool state; never automatically rebroadcast it. Do not share the JSON file among concurrent writers or replace a production database with it. Wire it into the operator trader service through a production transaction coordinator before enabling public signers.

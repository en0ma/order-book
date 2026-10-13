# Pre-deployment fee/collateral reconciliation

This module checks declared aggregate token liabilities, conservative insurance reserve and protocol-fee balances, and plans fee routing without floating-point precision loss. **It does not read on-chain balances or authorize/execute withdrawals.** Callers must source accurate comprehensive liabilities across local accounts, portfolio vaults and realized/unrealized PnL; those liabilities are not derivable from a single Core snapshot. Production fee withdrawal and recipient permissions require an independently reviewed on-chain implementation, solvency invariant, withdrawal test matrix and external audit.


## Conservative fee-surplus certificate (operator reference)

The exported `@en0ma/order-book-operator/fee-surplus-attestation` function
`attestFeeSurplus` accepts a canonical chain ID, block number and block hash
together with **eight independently sourced integer amounts**: physical custody,
positive settled account claims, outstanding portfolio claims, insurance reserves,
accrued fees, pending maker rebates, other unpriced/unsettled liabilities and
bad-debt exposure. It rejects missing, negative or non-integer amounts, missing
block provenance and underbacked snapshots. It conservatively reserves every
declared liability and caps its `candidateDistributableFees` by both accrued
fees and custody beyond those liabilities.

**This certificate is not a proof of distributability or a withdrawal
authorization.** An integrating DEX must obtain all liabilities from
trustworthy comprehensive sources at one finalized block, without double
counting between standalone and portfolio custody, and must reconcile aggregate
positions, maker pending claims, funding, debt, settlement timing, token behavior
and actual vaults. The function cannot know if an account or order was omitted,
whether the reported custody covers the right asset, or whether future market
losses would consume reserves. In particular, it makes no on-chain claim and
does **not** introduce a treasury payout, owner-only extraction path or actual
transfer. Only an independently reviewed on-chain proof and withdrawal state
machine could enable this in production.

## Physical custody-domain reconciliation

The optional `custody-domain-reconciliation` export consumes a complete snapshot **per physical token-holding contract**, not one snapshot per CLOB market. Multiple portfolio markets sharing the same vault must appear together in one custody domain. It refuses duplicate custody addresses, reused market IDs, mixed chain/block identity, mixed collateral assets and per-domain insolvency, then reports the sums of separately attested fee candidates. This forbids offsetting a deficient vault with excess tokens at another vault.

The caller must provide all relevant domains and all their market identifiers; the helper cannot independently discover omitted domains or prove market membership completeness. Each liability must be attributed exactly once to the contract actually holding the tokens, from a trustworthy finalized-block source. This report is **non-authoritative off-chain diagnostic evidence**, not approval to transfer or net assets between custody domains.

### Independently verified custody inventory

Use `reconcileExpectedCustodyDomains(domains, expected)` where `expected` is
constructed **independently** from the deployment's verified chain configuration,
not copied from the submitted accounting report. The stricter API requires
every expected physical custody address to appear once, with the exact assigned
market IDs and collateral token. It rejects an omitted custody domain, missing
market, substituted address, duplicated market or changed collateral token.
This closes the logical omission allowed by checking only the reported domains.

An integrator must still verify the expected roster is itself complete and
current at the attested canonical block, especially after deployments or market
migrations. A correct roster and complete liability inventory are separate
claims; this check does not independently enumerate accounts or prove fee
distributability. It never transfers funds.

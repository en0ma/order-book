import test from "node:test";
import assert from "node:assert/strict";
import { attestFeeSurplus, attestFeeSurplusFromAccounts, attestFeeSurplusAgainstExpectedAccounts } from "../dist/fee-surplus-attestation.js";

const hash = "0x" + "a".repeat(64);
const base = {
  chainId: 1, blockNumber: 42, blockHash: hash,
  custodyTokenBalance: 300n,
  positiveSettledAccountClaims: 100n,
  outstandingPortfolioClaims: 50n,
  insuranceReserves: 20n,
  accruedProtocolFees: 40n,
  pendingMakerRebates: 30n,
  unpricedOrUnsettledLiabilities: 10n,
  badDebtExposure: 10n,
  completeLiabilityInventory: true,
  custodyDomainsReconciled: true,
};
test("surplus attestation reserves every declared liability before computing candidate", () => {
  const cert = attestFeeSurplus(base);
  assert.equal(cert.totalReserved, 260n);
  assert.equal(cert.unencumberedSurplus, 40n);
  assert.equal(cert.candidateDistributableFees, 40n);
  assert.equal(cert.blockHash, hash);
});
test("caps candidate below accrued fees when excess custody is smaller", () => {
  const cert = attestFeeSurplus({ ...base, custodyTokenBalance: 280n });
  assert.equal(cert.candidateDistributableFees, 20n);
});
test("rejects underfunding, missing liabilities and invalid provenance", () => {
  assert.throws(() => attestFeeSurplus({ ...base, custodyTokenBalance: 259n }), /insufficient custody/);
  assert.throws(() => attestFeeSurplus({ ...base, pendingMakerRebates: undefined }), /pendingMakerRebates/);
  assert.throws(() => attestFeeSurplus({ ...base, badDebtExposure: -1n }), /badDebtExposure/);
  assert.throws(() => attestFeeSurplus({ ...base, blockHash: "0xdead" }), /canonical block/);
});
test("maker rebates, unpriced positions and bad debt reduce the attested bound", () => {
  const higher = attestFeeSurplus({ ...base, pendingMakerRebates: 50n });
  assert.equal(higher.candidateDistributableFees, 20n);
  assert.equal(attestFeeSurplus({ ...base, unpricedOrUnsettledLiabilities: 50n }).candidateDistributableFees, 0n);
  assert.equal(attestFeeSurplus({ ...base, badDebtExposure: 50n }).candidateDistributableFees, 0n);
});

test("fails closed when liability enumeration or custody-domain proof is absent", () => {
  assert.throws(() => attestFeeSurplus({ ...base, completeLiabilityInventory: false }), /unverified complete/);
  assert.throws(() => attestFeeSurplus({ ...base, custodyDomainsReconciled: false }), /unverified complete/);
  assert.throws(() => attestFeeSurplus({ ...base, completeLiabilityInventory: undefined }), /unverified complete/);
  assert.throws(() => attestFeeSurplus({ ...base, custodyDomainsReconciled: undefined }), /unverified complete/);
  // Surplus arithmetic alone, even with huge physical custody, cannot certify completeness.
  assert.throws(() => attestFeeSurplus({
    ...base, custodyTokenBalance: 1_000_000n, completeLiabilityInventory: false,
  }), /unverified complete/);
});

const account = hex => "0x" + hex.repeat(40);
test("account-level settlement claims match certified positive aggregates", () => {
  const entries = [
    { account: account("1"), settledCashClaim: 125n, portfolioClaim: 70n },
    { account: account("2"), settledCashClaim: -25n, portfolioClaim: -90n },
    { account: account("3"), settledCashClaim: 25n, portfolioClaim: 10n },
  ];
  const snapshot = {
    ...base,
    positiveSettledAccountClaims: 150n,
    outstandingPortfolioClaims: 80n,
    custodyTokenBalance: 450n,
  };
  const cert = attestFeeSurplusFromAccounts(snapshot, entries);
  assert.equal(cert.totalReserved, 340n);
  assert.equal(cert.candidateDistributableFees, 40n);
  assert.throws(() => attestFeeSurplusFromAccounts({
    ...snapshot, positiveSettledAccountClaims: 125n,
  }, entries), /differ from declared aggregates/);
  assert.throws(() => attestFeeSurplusFromAccounts({
    ...snapshot, outstandingPortfolioClaims: 0n,
  }, entries), /differ from declared aggregates/);
  assert.throws(() => attestFeeSurplusFromAccounts(snapshot, entries.slice(0, 2)),
    /differ from declared aggregates/);
  assert.throws(() => attestFeeSurplusFromAccounts(snapshot, [entries[1], entries[0], entries[2]]),
    /sorted and unique/);
  assert.throws(() => attestFeeSurplusFromAccounts(snapshot, [entries[0], entries[0], entries[2]]),
    /sorted and unique/);
  assert.throws(() => attestFeeSurplusFromAccounts(snapshot, []), /nonempty claimant/);
  assert.throws(() => attestFeeSurplusFromAccounts(snapshot, [{
    ...entries[0], settledCashClaim: Number(125),
  }]), /invalid account liability/);
  assert.throws(() => attestFeeSurplusFromAccounts({
    ...snapshot, completeLiabilityInventory: false,
  }, entries), /unverified complete/);
});

test("independent roster detects claimant omitted from both submitted inventory and aggregates", () => {
  const actual = [
    { account: account("1"), settledCashClaim: 100n, portfolioClaim: 50n },
    { account: account("2"), settledCashClaim: 900n, portfolioClaim: 300n },
  ];
  const forged = { ...base, custodyTokenBalance: 300n };
  const supplied = [actual[0]];
  // The existing aggregate arithmetic cannot catch the missing account.
  assert.equal(attestFeeSurplusFromAccounts(forged, supplied).totalReserved, 260n);
  assert.throws(() => attestFeeSurplusAgainstExpectedAccounts(
    forged, supplied, actual.map(x => x.account),
  ), /differs from independent roster/);
  assert.throws(() => attestFeeSurplusAgainstExpectedAccounts(
    forged, actual, actual.map(x => x.account),
  ), /insufficient custody/);
  assert.throws(() => attestFeeSurplusAgainstExpectedAccounts(
    forged, supplied, [],
  ), /independent claimant roster required/);
  assert.throws(() => attestFeeSurplusAgainstExpectedAccounts(
    forged, supplied, [account("1"), account("1")],
  ), /differs from independent roster|sorted and unique/);
  const passing = attestFeeSurplusAgainstExpectedAccounts(
    forged, supplied, [account("1").toUpperCase().replace("0X", "0x")],
  );
  assert.equal(passing.totalReserved, 260n);
});

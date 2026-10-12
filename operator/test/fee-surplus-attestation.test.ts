import test from "node:test";
import assert from "node:assert/strict";
import { attestFeeSurplus } from "../dist/fee-surplus-attestation.js";

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

import test from "node:test";
import assert from "node:assert/strict";
import { reconcileCustodyDomains } from "../dist/custody-domain-reconciliation.js";

const addr = x => "0x" + x.repeat(40);
const hash = "0x" + "a".repeat(64);
const base = {
  chainId: 1, blockNumber: 101, blockHash: hash,
  collateralToken: addr("9"), custodyAddress: addr("1"),
  marketIds: ["ETH-PERP", "BTC-PERP"],
  custodyTokenBalance: 1000n,
  positiveSettledAccountClaims: 300n, outstandingPortfolioClaims: 200n,
  insuranceReserves: 100n, accruedProtocolFees: 100n,
  pendingMakerRebates: 100n, unpricedOrUnsettledLiabilities: 50n,
  badDebtExposure: 50n,
};
test("reconciles two distinct custody domains without treating markets as separate vault balances", () => {
  const report = reconcileCustodyDomains([base, {
    ...base, custodyAddress: addr("2"), marketIds: ["SOL-PERP"],
    custodyTokenBalance: 950n,
  }]);
  assert.equal(report.aggregateCustody, 1950n);
  assert.equal(report.aggregateReserved, 1800n);
  assert.equal(report.aggregateCandidateDistributableFees, 150n);
  assert.equal(report.domains.length, 2);
});
test("refuses duplicate vault address, market reuse, mixed block and mixed assets", () => {
  assert.throws(() => reconcileCustodyDomains([base, {
    ...base, custodyAddress: addr("1").toUpperCase().replace("0X", "0x"),
    marketIds: ["SOL-PERP"],
  }]), /duplicate physical custody/);
  assert.throws(() => reconcileCustodyDomains([base, {
    ...base, custodyAddress: addr("2"), marketIds: ["BTC-PERP"],
  }]), /market assigned/);
  assert.throws(() => reconcileCustodyDomains([base, {
    ...base, custodyAddress: addr("2"), marketIds: ["SOL-PERP"], blockNumber: 102,
  }]), /one canonical block/);
  assert.throws(() => reconcileCustodyDomains([base, {
    ...base, custodyAddress: addr("2"), marketIds: ["SOL-PERP"], collateralToken: addr("8"),
  }]), /mixed collateral tokens/);
});
test("does not net a deficient vault against an overfunded vault", () => {
  assert.throws(() => reconcileCustodyDomains([base, {
    ...base, custodyAddress: addr("2"), marketIds: ["SOL-PERP"], custodyTokenBalance: 899n,
  }]), /insufficient custody/);
});

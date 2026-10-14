export interface FeeSurplusSnapshot {
  chainId: number;
  blockNumber: number;
  blockHash: string;
  custodyTokenBalance: bigint;
  positiveSettledAccountClaims: bigint;
  outstandingPortfolioClaims: bigint;
  insuranceReserves: bigint;
  accruedProtocolFees: bigint;
  pendingMakerRebates: bigint;
  unpricedOrUnsettledLiabilities: bigint;
  badDebtExposure: bigint;
  completeLiabilityInventory: boolean;
  custodyDomainsReconciled: boolean;
}
export interface FeeSurplusCertificate {
  chainId: number;
  blockNumber: number;
  blockHash: string;
  totalReserved: bigint;
  unencumberedSurplus: bigint;
  candidateDistributableFees: bigint;
}
export declare function attestFeeSurplus(snapshot: FeeSurplusSnapshot): FeeSurplusCertificate;

export interface AccountLiabilityEntry {
  account: string;
  settledCashClaim: bigint;
  portfolioClaim: bigint;
}
export declare function attestFeeSurplusFromAccounts(
  snapshot: FeeSurplusSnapshot,
  accounts: readonly AccountLiabilityEntry[],
): FeeSurplusCertificate;

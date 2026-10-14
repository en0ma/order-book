/** Conservative off-chain solvency evidence. This module never transfers tokens.
 * All figures are base units from a common canonical block and trusted sources.
 */
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
  /** Independently reconciled exhaustive claimant/order inventory at this block. */
  completeLiabilityInventory: boolean;
  /** Proof all market custody domains and the ERC-20 asset identity match. */
  custodyDomainsReconciled: boolean;
}
export interface FeeSurplusCertificate {
  chainId: number;
  blockNumber: number;
  blockHash: string;
  totalReserved: bigint;
  unencumberedSurplus: bigint;
  /** Upper bound for further review, not an executable treasury allowance. */
  candidateDistributableFees: bigint;
}

export function attestFeeSurplus(snapshot: FeeSurplusSnapshot): FeeSurplusCertificate {
  if (!Number.isSafeInteger(snapshot.chainId) || snapshot.chainId <= 0 ||
      !Number.isSafeInteger(snapshot.blockNumber) || snapshot.blockNumber < 0 ||
      typeof snapshot.blockHash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(snapshot.blockHash)) {
    throw new TypeError("invalid canonical block identity");
  }
  if (snapshot.completeLiabilityInventory !== true || snapshot.custodyDomainsReconciled !== true) {
    throw new Error("unverified complete liabilities or custody domains; treasury payout disabled");
  }
  const keys = [
    "custodyTokenBalance", "positiveSettledAccountClaims",
    "outstandingPortfolioClaims", "insuranceReserves",
    "accruedProtocolFees", "pendingMakerRebates",
    "unpricedOrUnsettledLiabilities", "badDebtExposure",
  ] as const;
  for (const key of keys) {
    if (typeof snapshot[key] !== "bigint" || snapshot[key] < 0n) {
      throw new TypeError("missing or invalid nonnegative liability: " + key);
    }
  }
  const totalReserved =
    snapshot.positiveSettledAccountClaims +
    snapshot.outstandingPortfolioClaims +
    snapshot.insuranceReserves +
    snapshot.accruedProtocolFees +
    snapshot.pendingMakerRebates +
    snapshot.unpricedOrUnsettledLiabilities +
    snapshot.badDebtExposure;
  if (totalReserved > snapshot.custodyTokenBalance) {
    throw new Error("insufficient custody for comprehensive declared liabilities");
  }
  const unencumberedSurplus = snapshot.custodyTokenBalance - totalReserved;
  return {
    chainId: snapshot.chainId, blockNumber: snapshot.blockNumber,
    blockHash: snapshot.blockHash.toLowerCase(),
    totalReserved, unencumberedSurplus,
    candidateDistributableFees:
      snapshot.accruedProtocolFees < unencumberedSurplus
        ? snapshot.accruedProtocolFees : unencumberedSurplus,
  };
}

/**
 * Cross-check the supplied settled account liabilities against account-level
 * entries, rather than trusting an unaudited aggregate alone. Caller must
 * independently prove the roster is exhaustive from finalized-chain history.
 * These positive components intentionally do not net insolvent accounts'
 * deficits against unrelated claimants.
 */
export interface AccountLiabilityEntry {
  account: string;
  settledCashClaim: bigint;
  portfolioClaim: bigint;
}
const accountPattern = /^0x[0-9a-fA-F]{40}$/;

export function attestFeeSurplusFromAccounts(
  snapshot: FeeSurplusSnapshot,
  accounts: readonly AccountLiabilityEntry[],
): FeeSurplusCertificate {
  if (!Array.isArray(accounts) || accounts.length === 0) {
    throw new Error("nonempty claimant inventory required");
  }
  let previous = "";
  let positiveSettled = 0n;
  let positivePortfolio = 0n;
  for (const entry of accounts) {
    if (!entry || typeof entry.account !== "string" ||
        !accountPattern.test(entry.account) ||
        typeof entry.settledCashClaim !== "bigint" ||
        typeof entry.portfolioClaim !== "bigint") {
      throw new TypeError("invalid account liability entry");
    }
    const account = entry.account.toLowerCase();
    if (account <= previous) throw new Error("claimant roster must be sorted and unique");
    previous = account;
    if (entry.settledCashClaim > 0n) positiveSettled += entry.settledCashClaim;
    if (entry.portfolioClaim > 0n) positivePortfolio += entry.portfolioClaim;
  }
  if (positiveSettled !== snapshot.positiveSettledAccountClaims ||
      positivePortfolio !== snapshot.outstandingPortfolioClaims) {
    throw new Error("account-level positive liabilities differ from declared aggregates");
  }
  return attestFeeSurplus(snapshot);
}

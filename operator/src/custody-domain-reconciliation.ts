import { attestFeeSurplus, type FeeSurplusSnapshot, type FeeSurplusCertificate } from "./fee-surplus-attestation.js";

/** One physical token custody contract, not one market or a per-account view. */
export interface CustodyDomainSnapshot extends FeeSurplusSnapshot {
  custodyAddress: string;
  collateralToken: string;
  /** Complete market IDs sharing this custody source, unique across the entire report. */
  marketIds: readonly string[];
}
export interface ReconciledCustodyReport {
  chainId: number;
  blockNumber: number;
  blockHash: string;
  collateralToken: string;
  domains: readonly { custodyAddress: string; certificate: FeeSurplusCertificate }[];
  aggregateReserved: bigint;
  aggregateCustody: bigint;
  aggregateCandidateDistributableFees: bigint;
}
const addressPattern = /^0x[0-9a-fA-F]{40}$/;

/**
 * Refuses duplicate physical custody, market double counting and mixed token
 * or block reports. Each domain must already contain the FULL liabilities
 * for its physical custody contract, not a per-market slice.
 *
 * Aggregate candidate fees are an off-chain diagnostic, not authorization.
 */
export function reconcileCustodyDomains(
  domains: readonly CustodyDomainSnapshot[],
): ReconciledCustodyReport {
  if (!Array.isArray(domains) || domains.length === 0) {
    throw new TypeError("at least one custody domain is required");
  }
  const [first] = domains;
  const seenCustody = new Set<string>();
  const seenMarkets = new Set<string>();
  let aggregateReserved = 0n;
  let aggregateCustody = 0n;
  let aggregateCandidateDistributableFees = 0n;
  const reconciled: { custodyAddress: string; certificate: FeeSurplusCertificate }[] = [];
  for (const domain of domains) {
    if (!addressPattern.test(domain.custodyAddress) || !addressPattern.test(domain.collateralToken)) {
      throw new TypeError("invalid custody or token address");
    }
    const custodyAddress = domain.custodyAddress.toLowerCase();
    const token = domain.collateralToken.toLowerCase();
    if (seenCustody.has(custodyAddress)) throw new Error("duplicate physical custody domain");
    seenCustody.add(custodyAddress);
    if (token !== first.collateralToken.toLowerCase()) {
      throw new Error("mixed collateral tokens cannot be aggregated");
    }
    if (!Array.isArray(domain.marketIds) || domain.marketIds.length === 0) {
      throw new TypeError("custody domain requires complete market membership");
    }
    for (const marketId of domain.marketIds) {
      if (typeof marketId !== "string" || marketId.length === 0) {
        throw new TypeError("invalid custody market ID");
      }
      if (seenMarkets.has(marketId)) throw new Error("market assigned to multiple custody domains");
      seenMarkets.add(marketId);
    }
    const certificate = attestFeeSurplus(domain);
    if (certificate.chainId !== first.chainId ||
        certificate.blockNumber !== first.blockNumber ||
        certificate.blockHash !== first.blockHash.toLowerCase()) {
      throw new Error("custody domains must share one canonical block");
    }
    aggregateReserved += certificate.totalReserved;
    aggregateCustody += domain.custodyTokenBalance;
    aggregateCandidateDistributableFees += certificate.candidateDistributableFees;
    reconciled.push({ custodyAddress, certificate });
  }
  return {
    chainId: first.chainId, blockNumber: first.blockNumber,
    blockHash: first.blockHash.toLowerCase(),
    collateralToken: first.collateralToken.toLowerCase(),
    domains: reconciled, aggregateReserved, aggregateCustody,
    aggregateCandidateDistributableFees,
  };
}

/** Independently verified deployment inventory, not derived from submitted snapshots. */
export interface ExpectedCustodyDomain {
  custodyAddress: string;
  collateralToken: string;
  marketIds: readonly string[];
}

/**
 * Require full coverage of independently supplied custody/market inventory.
 * The expected roster must be obtained independently from an authoritative
 * finalized deployment configuration, never copied from the report itself.
 */
export function reconcileExpectedCustodyDomains(
  domains: readonly CustodyDomainSnapshot[],
  expected: readonly ExpectedCustodyDomain[],
): ReconciledCustodyReport {
  if (!Array.isArray(expected) || expected.length === 0) {
    throw new TypeError("authoritative custody inventory is required");
  }
  const report = reconcileCustodyDomains(domains);
  if (expected.length !== domains.length) {
    throw new Error("custody domain inventory count mismatch");
  }
  const actual = new Map(domains.map(domain => [domain.custodyAddress.toLowerCase(), domain]));
  const visited = new Set<string>();
  for (const record of expected) {
    if (typeof record.custodyAddress !== "string" ||
        !addressPattern.test(record.custodyAddress) ||
        typeof record.collateralToken !== "string" ||
        !addressPattern.test(record.collateralToken) ||
        !Array.isArray(record.marketIds) || record.marketIds.length === 0) {
      throw new TypeError("invalid authoritative custody inventory");
    }
    const key = record.custodyAddress.toLowerCase();
    if (visited.has(key)) throw new Error("duplicate authoritative custody domain");
    visited.add(key);
    const actualDomain = actual.get(key);
    if (!actualDomain) throw new Error("missing expected physical custody domain");
    if (actualDomain.collateralToken.toLowerCase() !== record.collateralToken.toLowerCase()) {
      throw new Error("custody domain collateral token mismatch");
    }
    const assigned = new Set(actualDomain.marketIds);
    const required = new Set<string>();
    for (const marketId of record.marketIds) {
      if (typeof marketId !== "string" || !marketId.length || required.has(marketId)) {
        throw new TypeError("invalid or repeated authoritative market ID");
      }
      required.add(marketId);
    }
    if (assigned.size !== required.size || [...required].some(id => !assigned.has(id))) {
      throw new Error("custody domain market inventory mismatch");
    }
  }
  return report;
}

import type { FeeSurplusSnapshot, FeeSurplusCertificate } from "./fee-surplus-attestation.js";
export interface CustodyDomainSnapshot extends FeeSurplusSnapshot {
  custodyAddress: string;
  collateralToken: string;
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
export declare function reconcileCustodyDomains(domains: readonly CustodyDomainSnapshot[]): ReconciledCustodyReport;

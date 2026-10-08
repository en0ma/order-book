import type { Address, OperatorManifest, OperatorRpcAdapter } from "./index.js";
import type { CanonicalLogEnvelope } from "./integration.js";
export interface JsonRpcTransport {
  request(method: string, params: readonly unknown[]): Promise<unknown>;
}
export interface RpcLog {
  address: Address;
  blockHash: string;
  blockNumber: string;
  transactionIndex: string;
  logIndex: string;
  topics: string[];
  data: string;
  removed?: boolean;
}
export interface CanonicalRpcOptions {
  decode(log: RpcLog, chainId: number): CanonicalLogEnvelope | undefined;
  markTicks?(manifest: OperatorManifest): Promise<Readonly<Record<string, number>>>;
  portfolioHealth?(accounts: readonly Address[], manifest: OperatorManifest): Promise<Readonly<Record<Address, { equity: bigint; requirement: bigint }>>>;
}
export declare function createCanonicalRpcAdapter(
  transport: JsonRpcTransport, options: CanonicalRpcOptions,
): OperatorRpcAdapter;

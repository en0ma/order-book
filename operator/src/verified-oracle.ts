import type { JsonRpcTransport } from "./rpc-adapter.js";
import type { OracleObservation } from "./trading-safety.js";
export interface OracleReadConfig { chainId: number; oracleAddress: string; maxAgeMs: number; sequencerRequired?: boolean }
export interface OracleReader {
  getChainId(): Promise<number>;
  readObservation(oracleAddress: string, blockTag: "latest"): Promise<{tick: number; timestampSeconds: number; sequencerUp: boolean}>;
}
/** Validates oracle observation provenance, freshness and chain identity; no optimistic defaults. */
export function createVerifiedOracleReader(reader: OracleReader, config: OracleReadConfig) {
  if (!Number.isSafeInteger(config.chainId) || config.chainId<=0 ||
      !/^0x[0-9a-fA-F]{40}$/.test(config.oracleAddress) ||
      !Number.isSafeInteger(config.maxAgeMs) || config.maxAgeMs<=0) throw new TypeError("invalid oracle configuration");
  const {chainId,oracleAddress,maxAgeMs,sequencerRequired=true}=config;
  return async function observation(nowMs: number): Promise<OracleObservation> {
    if (!Number.isSafeInteger(nowMs) || nowMs<0) throw new Error("invalid local clock");
    if (await reader.getChainId()!==chainId) throw new Error("oracle RPC chain mismatch");
    const value=await reader.readObservation(oracleAddress,"latest");
    if (!Number.isSafeInteger(value?.tick) || value.tick<0 || value.tick>65535 ||
      !Number.isSafeInteger(value?.timestampSeconds) || value.timestampSeconds<0 ||
      typeof value?.sequencerUp!=="boolean") throw new Error("invalid oracle observation");
    const observedAtMs=value.timestampSeconds*1000;
    if (!Number.isSafeInteger(observedAtMs)||observedAtMs>nowMs||
        nowMs-observedAtMs>maxAgeMs || (sequencerRequired&&value.sequencerUp!==true)) {
      throw new Error("oracle observation stale, future, or sequencer unavailable");
    }
    // Preserve sequencer signal even when operator disables the hard requirement.
    return {tick:value.tick,observedAtMs,sequencerUp:value.sequencerUp};
  };
}

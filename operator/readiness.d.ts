import type { ApiSnapshot, OperatorDiagnostics } from "./api.js";
export interface ReadinessPolicy { maxLagBlocks?: number; requireDiagnostics?: boolean; }
export interface ReadinessResult {
  ready: boolean;
  reason: "ready" | "missing_head" | "missing_diagnostics" | "stalled" | "lagging" | "head_mismatch";
  headBlock?: number;
  safeHead?: number;
  lagBlocks?: number;
}
export declare function checkReadiness(snapshot: ApiSnapshot, diagnostics?: OperatorDiagnostics, policy?: ReadinessPolicy): ReadinessResult;

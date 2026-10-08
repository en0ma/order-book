import type { ApiSnapshot, OperatorDiagnostics } from "./api.js";

export interface ReadinessPolicy {
  /** Maximum chain-block distance from the latest safe head (default: 0). */
  maxLagBlocks?: number;
  /** Require an available, non-stalled operator diagnostic record. */
  requireDiagnostics?: boolean;
}
export interface ReadinessResult {
  ready: boolean;
  reason: "ready" | "missing_head" | "missing_diagnostics" | "stalled" | "lagging" | "head_mismatch";
  headBlock?: number;
  safeHead?: number;
  lagBlocks?: number;
}
/** Pure readiness gate; does not infer finality from a block number alone. */
export function checkReadiness(
  snapshot: ApiSnapshot,
  diagnostics?: OperatorDiagnostics,
  policy: ReadinessPolicy = {},
): ReadinessResult {
  const maxLag = policy.maxLagBlocks ?? 0;
  if (!Number.isSafeInteger(maxLag) || maxLag < 0 || maxLag > 10_000) {
    throw new RangeError("invalid maximum operator lag");
  }
  const head = snapshot.head;
  if (!head || !Number.isSafeInteger(head.number) || !head.hash) {
    return { ready: false, reason: "missing_head" };
  }
  if (!diagnostics) {
    return policy.requireDiagnostics === false
      ? { ready: true, reason: "ready", headBlock: head.number }
      : { ready: false, reason: "missing_diagnostics", headBlock: head.number };
  }
  const validCounter = (n: number) => Number.isSafeInteger(n) && n >= 0;
  if (!validCounter(diagnostics.headBlock ?? -1) ||
      !validCounter(diagnostics.safeHead) ||
      !validCounter(diagnostics.lagBlocks) ||
      !validCounter(diagnostics.remoteHead) ||
      !validCounter(diagnostics.appliedBlocks)) {
    return { ready: false, reason: "invalid_diagnostics", headBlock: head.number };
  }
  if (diagnostics.headBlock !== head.number || diagnostics.safeHead < head.number) {
    return { ready: false, reason: "head_mismatch", headBlock: head.number, safeHead: diagnostics.safeHead };
  }
  const lag = diagnostics.safeHead - head.number;
  if (diagnostics.status === "stalled") {
    return { ready: false, reason: "stalled", headBlock: head.number, safeHead: diagnostics.safeHead, lagBlocks: lag };
  }
  if (lag > maxLag || diagnostics.lagBlocks > maxLag) {
    return { ready: false, reason: "lagging", headBlock: head.number, safeHead: diagnostics.safeHead, lagBlocks: lag };
  }
  return { ready: true, reason: "ready", headBlock: head.number, safeHead: diagnostics.safeHead, lagBlocks: lag };
}

/** Independent preflight guard for trader and maker write services. Not an on-chain pause. */
export interface OracleObservation { tick: number; observedAtMs: number; sequencerUp: boolean }
export interface SafetyPolicy { maxAgeMs: number; maxDeviationTicks: number; referenceTick: number }
export type TradingAction = "increase-risk" | "reduce-risk" | "cancel" | "settle" | "withdraw";
export interface TradingSafetyGate {
  status(): { halted: boolean; reason?: string };
  halt(reason: string): void;
  resume(): void;
  check(action: TradingAction, observation: OracleObservation, nowMs: number): void;
}
export function createTradingSafetyGate(policy: SafetyPolicy): TradingSafetyGate {
  if (!Number.isSafeInteger(policy.maxAgeMs) || policy.maxAgeMs < 1 ||
      !Number.isSafeInteger(policy.maxDeviationTicks) || policy.maxDeviationTicks < 0 ||
      !Number.isSafeInteger(policy.referenceTick) || policy.referenceTick < 0 || policy.referenceTick > 65535) {
    throw new RangeError("invalid safety policy");
  }
  let reason: string | undefined;
  return {
    status: () => ({ halted: reason !== undefined, ...(reason ? { reason } : {}) }),
    halt(message) { if (!message.trim()) throw new Error("halt reason required"); reason = message; },
    resume() { reason = undefined; },
    check(action, observation, nowMs) {
      if (!["increase-risk","reduce-risk","cancel","settle","withdraw"].includes(action)) {
        throw new Error("unknown trading action");
      }
      // Cancellation and settlement must remain available during operator risk-off.
      if (action === "cancel" || action === "settle") return;
      if (reason) throw new Error("trading safety gate halted: " + reason);
      if (!Number.isSafeInteger(nowMs) || !Number.isSafeInteger(observation?.observedAtMs) ||
          !Number.isSafeInteger(observation?.tick) || observation.tick < 0 ||
          observation.tick > 65535 || observation.observedAtMs > nowMs ||
          nowMs - observation.observedAtMs > policy.maxAgeMs || observation.sequencerUp !== true ||
          Math.abs(observation.tick - policy.referenceTick) > policy.maxDeviationTicks) {
        throw new Error("trading safety gate rejected unreliable mark or sequencer");
      }
      // Reduce-risk and withdrawals also require reliable state; simulation must enforce actual risk reduction.
    },
  };
}

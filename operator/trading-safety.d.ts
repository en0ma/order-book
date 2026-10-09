export interface OracleObservation { tick: number; observedAtMs: number; sequencerUp: boolean }
export interface SafetyPolicy { maxAgeMs: number; maxDeviationTicks: number; referenceTick: number }
export type TradingAction = "increase-risk" | "reduce-risk" | "cancel" | "settle" | "withdraw";
export interface TradingSafetyGate {
 status(): { halted: boolean; reason?: string };
 halt(reason: string): void;
 resume(): void;
 check(action: TradingAction, observation: OracleObservation, nowMs: number): void;
}
export declare function createTradingSafetyGate(policy: SafetyPolicy): TradingSafetyGate;

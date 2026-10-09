import { reconcileMakerQuotes, type MakerQuoteTarget, type MakerRiskLimits } from "./mm-reconcile.js";
import type { TradingSafetyGate, OracleObservation } from "./trading-safety.js";

export interface MakerExecutionAdapter {
  canonicalQuotes(): Promise<readonly MakerQuoteTarget[]>;
  simulate(updates: readonly MakerQuoteTarget[]): Promise<void>;
  submit(updates: readonly MakerQuoteTarget[]): Promise<string>;
}
export interface MakerExecutionResult { kind: "unchanged" | "submitted"; updates: readonly MakerQuoteTarget[]; txHash?: string }
/**
 * Stateless quote convergence against canonical state, never cached intent.
 * Only one execution may run concurrently per coordinator instance.
 */
export function createMakerExecutionCoordinator(
  adapter: MakerExecutionAdapter, gate: TradingSafetyGate,
  limits: MakerRiskLimits, observation: () => Promise<OracleObservation>,
  now: () => number,
) {
  let busy=false;
  return {
    async reconcile(target: readonly MakerQuoteTarget[]): Promise<MakerExecutionResult> {
      if (busy) throw new Error("maker quote refresh already running");
      busy=true;
      try {
        const current=await adapter.canonicalQuotes();
        const updates=reconcileMakerQuotes(current,target,limits);
        if (updates.length===0) return {kind:"unchanged",updates};
        // Risk-off may still cancel all quotes but must not permit any new positive quote.
        const onlyCancels=updates.every(q=>q.lots===0n);
        if (!onlyCancels) gate.check("increase-risk",await observation(),now());
        else gate.check("cancel",{} as OracleObservation,now());
        await adapter.simulate(updates);
        // Changes since simulation can cause stale cancellation, so verify canonical targets.
        const latest=await adapter.canonicalQuotes();
        const serialize=(quotes:readonly MakerQuoteTarget[]) => JSON.stringify(
          [...quotes].sort((a,b)=>a.side-b.side||a.tick-b.tick),
          (_k,v)=>typeof v==="bigint"?v.toString():v);
        if (serialize(latest)!==serialize(current)) {
          throw new Error("canonical managed quotes changed during simulation");
        }
        if (!onlyCancels)gate.check("increase-risk",await observation(),now());
        const txHash=await adapter.submit(updates);
        if (!/^0x[0-9a-fA-F]{64}$/.test(txHash)) throw new Error("invalid quote transaction hash");
        return {kind:"submitted",updates,txHash};
      } finally {busy=false;}
    },
  };
}

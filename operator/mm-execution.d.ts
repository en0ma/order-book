import type {MakerQuoteTarget,MakerRiskLimits} from "./mm-reconcile.js";
import type {TradingSafetyGate,OracleObservation} from "./trading-safety.js";
export interface MakerExecutionAdapter {canonicalQuotes():Promise<readonly MakerQuoteTarget[]>;simulate(updates:readonly MakerQuoteTarget[]):Promise<void>;submit(updates:readonly MakerQuoteTarget[]):Promise<string>}
export interface MakerExecutionResult {kind:"unchanged"|"submitted";updates:readonly MakerQuoteTarget[];txHash?:string}
export declare function createMakerExecutionCoordinator(adapter:MakerExecutionAdapter,gate:TradingSafetyGate,limits:MakerRiskLimits,observation:()=>Promise<OracleObservation>,now:()=>number):{reconcile(target:readonly MakerQuoteTarget[]):Promise<MakerExecutionResult>};

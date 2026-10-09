import {assessExchangeHealth, type ExchangeHealth, type ExchangePolicy, type ExchangeSignals} from "./exchange-health.js";
export interface LaunchChecks {
 deploymentVerified: boolean;
 chainIdMatches: boolean;
 auditedConfiguration: boolean;
 guardianConfigured: boolean;
 riskIncreasePaused: boolean;
 canonicalStorageDurable: boolean;
 writableSignerConfigured: boolean;
}
export interface LaunchDecision {admitTrading:boolean;admitRiskReduction:boolean;reasons:string[];health:ExchangeHealth}
/**
 * Explicit launch admission boundary: no implicit default to production readiness.
 * The audit flag is externally attested, not evidence that an audit occurred.
 */
export function evaluateLaunch(checks:LaunchChecks,signals:ExchangeSignals,policy:ExchangePolicy):LaunchDecision{
 const health=assessExchangeHealth(signals,policy);
 const reasons=[...health.blockers];
 for(const [key,ok] of Object.entries(checks)){
   if(key==="riskIncreasePaused"){if(ok!==false)reasons.push("on-chain risk-off active or unknown");}
   else if(ok!==true)reasons.push("launch prerequisite failed: "+key);
 }
 return {admitTrading:reasons.length===0,admitRiskReduction:checks.deploymentVerified===true &&
   checks.chainIdMatches===true && checks.canonicalStorageDurable===true,
   reasons,health};
}
export function requireLaunchReady(checks:LaunchChecks,signals:ExchangeSignals,policy:ExchangePolicy):void {
 const state=evaluateLaunch(checks,signals,policy);
 if(!state.admitTrading)throw new Error("exchange launch denied: "+state.reasons.join("; "));
}

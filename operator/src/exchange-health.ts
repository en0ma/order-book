/** Self-hosted operator health policy. No hosted monitoring service is created. */
export interface ExchangeSignals {
  canonicalHead: number; remoteHead: number;
  oldestOracleAgeMs: number; sequencerUp: boolean;
  keeperPending: number; oldestKeeperAgeMs: number;
  rpcWitnessesAgree: boolean; recoveryReady: boolean;
  signerAvailable: boolean;
}
export interface ExchangePolicy {
  maxHeadLag: number; maxOracleAgeMs: number;
  maxKeeperAgeMs: number; maxKeeperPending: number;
}
export interface ExchangeHealth {
  ready: boolean;
  blockers: string[];
  warnings: string[];
}
export function assessExchangeHealth(signals: ExchangeSignals, policy: ExchangePolicy):ExchangeHealth {
 const blockers:string[]=[];
 const warnings:string[]=[];
 if (![policy.maxHeadLag,policy.maxOracleAgeMs,policy.maxKeeperAgeMs,policy.maxKeeperPending,
    signals.canonicalHead,signals.remoteHead,signals.oldestOracleAgeMs,
    signals.keeperPending,signals.oldestKeeperAgeMs].every(v=>Number.isSafeInteger(v)&&v>=0)) {
   return {ready:false,blockers:["invalid operator health metrics"],warnings};
 }
 if(!signals.recoveryReady)blockers.push("canonical recovery not ready");
 if(!signals.rpcWitnessesAgree)blockers.push("RPC witness disagreement");
 if(!signals.sequencerUp)blockers.push("sequencer unavailable");
 if(signals.oldestOracleAgeMs>policy.maxOracleAgeMs)blockers.push("stale oracle");
 if(signals.remoteHead<signals.canonicalHead||signals.remoteHead-signals.canonicalHead>policy.maxHeadLag)
   blockers.push("canonical lag exceeded");
 if(!signals.signerAvailable)blockers.push("keeper signer unavailable");
 if(signals.keeperPending>policy.maxKeeperPending)warnings.push("keeper backlog above limit");
 if(signals.oldestKeeperAgeMs>policy.maxKeeperAgeMs)warnings.push("keeper queue age above limit");
 return {ready:blockers.length===0,blockers,warnings};
}
export function createIncidentController() {
 let acknowledged=false;
 let incident:string|undefined;
 return {
  open(reason:string){if(!reason.trim())throw new Error("incident reason required");incident=reason;acknowledged=false;},
  acknowledge(){if(!incident)throw new Error("no active incident");acknowledged=true;},
  clear(health:ExchangeHealth){if(!incident) return;
   if(!acknowledged||!health.ready)throw new Error("cannot clear incident before acknowledgement and readiness");
   incident=undefined;acknowledged=false;
  },
  status:()=>({active:incident!==undefined,reason:incident,acknowledged}),
 };
}

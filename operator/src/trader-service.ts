import type { TradingSafetyGate, OracleObservation, TradingAction } from "./trading-safety.js";
export interface TraderPlan { target: string; functionName: string; args: readonly unknown[] }
export interface TraderExecutor {
  simulate(plan: TraderPlan): Promise<void>;
  submit(plan: TraderPlan, idempotencyKey: string): Promise<string>;
  receipt(txHash: string): Promise<"pending" | "confirmed" | "reverted">;
}
export interface TraderRequest {
  key: string; plan: TraderPlan; action: TradingAction;
  observation(): Promise<OracleObservation>; now(): number;
}
export interface TraderReceipt { key: string; txHash: string; status: "pending" | "confirmed" | "reverted" }
export function createTraderOrderService(executor: TraderExecutor, gate: TradingSafetyGate) {
 const pending=new Map<string,{ fingerprint:string; receipt:TraderReceipt }>();
 const inflight=new Map<string,Promise<TraderReceipt>>();
 function fingerprint(request:TraderRequest):string {
  return JSON.stringify([request.plan.target,request.plan.functionName,request.plan.args],(_key,value)=>
    typeof value==="bigint" ? value.toString()+"n" : value);
 }
 async function submit(request:TraderRequest):Promise<TraderReceipt> {
   if (!request.key.trim()) throw new Error("idempotency key required");
   if (!/^0x[0-9a-fA-F]{40}$/.test(request.plan.target) || !request.plan.functionName) throw new Error("invalid trading plan");
   const id=request.key,print=fingerprint(request),old=pending.get(id);
   if (old) {if(old.fingerprint!==print)throw new Error("idempotency conflict");return old.receipt;}
   if(inflight.has(id))return inflight.get(id)!;
   const run=(async()=>{
     const observation=await request.observation();gate.check(request.action,observation,request.now());
     await executor.simulate(request.plan);
     // Recheck near submission because simulation and observation can become stale.
     gate.check(request.action,await request.observation(),request.now());
     const txHash=await executor.submit(request.plan,id);
     if (!/^0x[0-9a-fA-F]{64}$/.test(txHash))throw new Error("invalid transaction hash");
     const receipt={key:id,txHash,status:"pending" as const};
     pending.set(id,{fingerprint:print,receipt});return receipt;
   })();
   inflight.set(id,run);
   try{return await run;}finally{inflight.delete(id);}
 }
 async function reconcile(key:string):Promise<TraderReceipt> {
   const saved=pending.get(key);if(!saved)throw new Error("unknown trader order");
   const status=await executor.receipt(saved.receipt.txHash);
   if (!["pending","confirmed","reverted"].includes(status))throw new Error("invalid receipt state");
   saved.receipt={...saved.receipt,status};return saved.receipt;
 }
 return {submit,reconcile,status:(key:string)=>pending.get(key)?.receipt};
}

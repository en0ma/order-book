import type {TradingSafetyGate,OracleObservation,TradingAction} from "./trading-safety.js";
export interface TraderPlan {target:string;functionName:string;args:readonly unknown[]}
export interface TraderExecutor {simulate(plan:TraderPlan):Promise<void>;submit(plan:TraderPlan,idempotencyKey:string):Promise<string>;receipt(txHash:string):Promise<"pending"|"confirmed"|"reverted">}
export interface TraderRequest {key:string;plan:TraderPlan;action:TradingAction;observation():Promise<OracleObservation>;now():number}
export interface TraderReceipt {key:string;txHash:string;status:"pending"|"confirmed"|"reverted"}
export declare function createTraderOrderService(executor:TraderExecutor,gate:TradingSafetyGate):{submit(request:TraderRequest):Promise<TraderReceipt>;reconcile(key:string):Promise<TraderReceipt>;status(key:string):TraderReceipt|undefined};

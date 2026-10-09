import test from "node:test";
import assert from "node:assert/strict";
import {createTraderOrderService} from "../dist/trader-service.js";
import {createTradingSafetyGate} from "../dist/trading-safety.js";
const mark={tick:100,observedAtMs:1000,sequencerUp:true};
const plan={target:"0x"+"1".repeat(40),functionName:"take",args:[1,100,10n]};
test("trader submission simulates, double-checks oracle and deduplicates confirmations",async()=>{
 let sims=0,txs=0;
 const api=createTraderOrderService({simulate:async()=>{sims++},submit:async()=>{txs++;return "0x"+"a".repeat(64)},receipt:async()=> "confirmed"},
 createTradingSafetyGate({maxAgeMs:200,maxDeviationTicks:10,referenceTick:100}));
 const request={key:"k",plan,action:"increase-risk",observation:async()=>mark,now:()=>1100};
 const a=await Promise.all([api.submit(request),api.submit(request)]);
 assert.equal(txs,1);assert.equal(sims,1);assert.deepEqual(a[0],a[1]);
 assert.equal((await api.reconcile("k")).status,"confirmed");
 await assert.rejects(api.submit({...request,plan:{...plan,args:[2]}}),/conflict/);
});
test("stale oracle halts order before simulation or signing",async()=>{
 let submitted=false;
 const api=createTraderOrderService({simulate:async()=>{},submit:async()=>{submitted=true;return "0x"+"a".repeat(64)},receipt:async()=> "pending"},
 createTradingSafetyGate({maxAgeMs:10,maxDeviationTicks:10,referenceTick:100}));
 await assert.rejects(api.submit({key:"bad",plan,action:"increase-risk",observation:async()=>mark,now:()=>1200}),/unreliable/);
 assert.equal(submitted,false);
});

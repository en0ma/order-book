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

test("cancel and settlement remain available without oracle reads",async()=>{
 let oracleReads=0;
 const api=createTraderOrderService({simulate:async()=>{},submit:async()=> "0x"+"b".repeat(64),receipt:async()=>"pending"},
 createTradingSafetyGate({maxAgeMs:1,maxDeviationTicks:0,referenceTick:100}));
 const result=await api.submit({key:"cancel",plan,action:"cancel",observation:async()=>{oracleReads++;throw Error("oracle offline")},now:()=>1000});
 assert.equal(result.status,"pending");assert.equal(oracleReads,0);
});
test("concurrent conflicting order plans cannot share idempotency key",async()=>{
 let release;
 const pending=new Promise(resolve=>release=resolve);
 const api=createTraderOrderService({simulate:async()=>{await pending},submit:async()=> "0x"+"a".repeat(64),receipt:async()=>"pending"},
 createTradingSafetyGate({maxAgeMs:200,maxDeviationTicks:10,referenceTick:100}));
 const base={key:"conflict",plan,action:"increase-risk",observation:async()=>mark,now:()=>1100};
 const first=api.submit(base);
 await assert.rejects(api.submit({...base,plan:{...plan,args:[999n]}}),/idempotency conflict/);
 release();await first;
});
test("late pending receipts cannot regress confirmed state",async()=>{
 let queries=0;let firstRelease;
 const delayed=new Promise(resolve=>firstRelease=resolve);
 const api=createTraderOrderService({simulate:async()=>{},submit:async()=> "0x"+"a".repeat(64),
 receipt:async()=>{queries++;if(queries===1){await delayed;return "pending"}return "confirmed"}},
 createTradingSafetyGate({maxAgeMs:200,maxDeviationTicks:10,referenceTick:100}));
 await api.submit({key:"receipt",plan,action:"increase-risk",observation:async()=>mark,now:()=>1100});
 const earlier=api.reconcile("receipt");
 const later=await api.reconcile("receipt");assert.equal(later.status,"confirmed");
 firstRelease();assert.equal((await earlier).status,"confirmed");
 assert.equal(api.status("receipt").status,"confirmed");
});

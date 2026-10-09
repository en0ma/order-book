import test from "node:test";
import assert from "node:assert/strict";
import {createMakerExecutionCoordinator} from "../dist/mm-execution.js";
import {createTradingSafetyGate} from "../dist/trading-safety.js";
const gate=createTradingSafetyGate({maxAgeMs:500,maxDeviationTicks:10,referenceTick:100});
const limits={maxLotsPerQuote:100n,maxTotalLots:200n,maxQuotes:3};
const mark=async()=>({tick:100,observedAtMs:1000,sequencerUp:true});
test("canonical quote convergence submits sorted changed keys only",async()=>{
 let writes=0,reads=0;
 const api=createMakerExecutionCoordinator({canonicalQuotes:async()=>{reads++;return [{side:0,tick:99,lots:10n}]},
 simulate:async updates=>{assert.equal(updates.length,2)},submit:async()=>{writes++;return "0x"+"a".repeat(64)}},gate,limits,mark,()=>1100);
 const r=await api.reconcile([{side:1,tick:101,lots:20n}]);
 assert.equal(r.kind,"submitted");assert.equal(writes,1);assert.equal(reads,2);
});
test("fail-closed stale quote state stops broadcast",async()=>{
 let reads=0,writes=0;
 const api=createMakerExecutionCoordinator({canonicalQuotes:async()=>{reads++;return reads===1?[]:[{side:0,tick:99,lots:1n}]},
 simulate:async()=>{},submit:async()=>{writes++;return "0x"+"a".repeat(64)}},gate,limits,mark,()=>1100);
 await assert.rejects(api.reconcile([{side:0,tick:100,lots:20n}]),/changed/);
 assert.equal(writes,0);
});
test("risk-off allows cancellation without a functioning oracle",async()=>{
 const halt=createTradingSafetyGate({maxAgeMs:500,maxDeviationTicks:10,referenceTick:100});
 halt.halt("incident");
 let writes=0;
 const api=createMakerExecutionCoordinator({canonicalQuotes:async()=>[{side:0,tick:99,lots:20n}],
 simulate:async()=>{},submit:async()=>{writes++;return "0x"+"a".repeat(64)}},
 halt,limits,async()=>{throw Error("offline")},()=>1100);
 assert.equal((await api.reconcile([])).kind,"submitted");assert.equal(writes,1);
});

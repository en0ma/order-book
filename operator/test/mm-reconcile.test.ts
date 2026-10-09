import test from "node:test";
import assert from "node:assert/strict";
import {createMakerQuoteController,reconcileMakerQuotes} from "../dist/mm-reconcile.js";
const limits={maxLotsPerQuote:100n,maxTotalLots:150n,maxQuotes:3};
test("maker restart reconciliation cancels stale keys and sorts updates",()=>{
 const old=[{side:1,tick:105,lots:20n},{side:0,tick:90,lots:50n}];
 const desired=[{side:0,tick:91,lots:60n},{side:1,tick:105,lots:20n}];
 assert.deepEqual(reconcileMakerQuotes(old,desired,limits),[
  {side:0,tick:90,lots:0n},{side:0,tick:91,lots:60n}]);
});
test("MM controller enforces aggregate exposure, duplicates and risk-off cancel-only",()=>{
 const x=createMakerQuoteController(limits);
 assert.throws(()=>x.plan([],[{side:0,tick:1,lots:90n},{side:1,tick:2,lots:90n}]),/exposure/);
 assert.throws(()=>x.plan([],[{side:0,tick:1,lots:10n},{side:0,tick:1,lots:10n}]),/duplicate/);
 x.stop();
 assert.throws(()=>x.plan([],[{side:0,tick:1,lots:1n}]),/kill switch/);
 assert.deepEqual(x.plan([{side:0,tick:1,lots:5n}],[]),[{side:0,tick:1,lots:0n}]);
});

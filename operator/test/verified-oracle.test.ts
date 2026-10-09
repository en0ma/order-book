import test from "node:test";
import assert from "node:assert/strict";
import {createVerifiedOracleReader} from "../dist/verified-oracle.js";
const oracleAddress="0x"+"1".repeat(40);
const config={chainId:1,oracleAddress,maxAgeMs:2000};
const make=(value,chain=1)=>({getChainId:async()=>chain,readObservation:async()=>value});
test("accepts authenticated fresh oracle observation only on expected chain",async()=>{
 const read=createVerifiedOracleReader(make({chainId:1,tick:100,timestampSeconds:10,sequencerUp:true}),config);
 assert.deepEqual(await read(11000),{tick:100,observedAtMs:10000,sequencerUp:true});
 await assert.rejects(createVerifiedOracleReader(make({chainId:1,tick:100,timestampSeconds:10,sequencerUp:true},2),config)(11000),/chain mismatch/);
});
test("fails closed on stale, future, invalid, sequencer-down and malformed readings",async()=>{
 for(const [value,now] of [
  [{chainId:1,tick:100,timestampSeconds:10,sequencerUp:true},15000],
  [{chainId:1,tick:100,timestampSeconds:15,sequencerUp:true},11000],
  [{chainId:1,tick:100,timestampSeconds:10,sequencerUp:false},11000],
  [{chainId:1,tick:-1,timestampSeconds:10,sequencerUp:true},11000],
  [{chainId:1,tick:100,timestampSeconds:10,sequencerUp:"true"},11000]]) {
    await assert.rejects(createVerifiedOracleReader(make(value),config)(now));
 }
});
test("snapshot of validated configuration resists mutation",async()=>{
 const mutable={...config};const read=createVerifiedOracleReader(make({chainId:1,tick:100,timestampSeconds:10,sequencerUp:true}),mutable);
 mutable.chainId=2;mutable.maxAgeMs=1;mutable.oracleAddress="invalid";
 assert.equal((await read(11000)).tick,100);
});

test("observation carrying a different chain identity is rejected",async()=>{
 const read=createVerifiedOracleReader(make({chainId:2,tick:100,timestampSeconds:10,sequencerUp:true}),config);
 await assert.rejects(read(11000),/chain mismatch/);
});
test("invalid sequencer policy cannot weaken default enforcement",()=>{
 for (const bad of [null,0,"", "false"]) assert.throws(()=>createVerifiedOracleReader(make({chainId:1,tick:100,timestampSeconds:10,sequencerUp:true}),{...config,sequencerRequired:bad}),/invalid oracle configuration/);
});

import test from "node:test";
import assert from "node:assert/strict";
import {assessExchangeHealth,createIncidentController} from "../dist/exchange-health.js";
const policy={maxHeadLag:2,maxOracleAgeMs:500,maxKeeperAgeMs:1000,maxKeeperPending:10};
const state={canonicalHead:100,remoteHead:100,oldestOracleAgeMs:200,sequencerUp:true,keeperPending:0,
 oldestKeeperAgeMs:0,rpcWitnessesAgree:true,recoveryReady:true,signerAvailable:true};
test("readiness rejects oracle, RPC, sequencer and recovery faults",()=>{
 const failures=[["stale oracle",{oldestOracleAgeMs:501}],["RPC witness disagreement",{rpcWitnessesAgree:false}],
  ["sequencer unavailable",{sequencerUp:false}],["canonical recovery not ready",{recoveryReady:false}],
  ["canonical lag exceeded",{remoteHead:110}],["keeper signer unavailable",{signerAvailable:false}]];
 for(const [code,changed] of failures){
  const health=assessExchangeHealth({...state,...changed},policy);
  assert.equal(health.ready,false);assert.ok(health.blockers.includes(code));
 }
 assert.equal(assessExchangeHealth(state,policy).ready,true);
});
test("incident requires explicit acknowledgement and restored health",()=>{
 const controller=createIncidentController();controller.open("stale mark");
 assert.throws(()=>controller.clear(assessExchangeHealth(state,policy)),/acknowledgement/);
 controller.acknowledge();
 assert.throws(()=>controller.clear(assessExchangeHealth({...state,sequencerUp:false},policy)),/readiness/);
 controller.clear(assessExchangeHealth(state,policy));
 assert.equal(controller.status().active,false);
});

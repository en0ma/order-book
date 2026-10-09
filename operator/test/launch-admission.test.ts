import test from "node:test";
import assert from "node:assert/strict";
import {evaluateLaunch,requireLaunchReady} from "../dist/launch-admission.js";
const signals={canonicalHead:99,remoteHead:99,oldestOracleAgeMs:10,sequencerUp:true,
 keeperPending:0,oldestKeeperAgeMs:0,rpcWitnessesAgree:true,recoveryReady:true,signerAvailable:true};
const policy={maxHeadLag:2,maxOracleAgeMs:500,maxKeeperAgeMs:1000,maxKeeperPending:10};
const checks={deploymentVerified:true,chainIdMatches:true,auditedConfiguration:true,guardianConfigured:true,
 riskIncreasePaused:false,canonicalStorageDurable:true,writableSignerConfigured:true};
test("launch blocks unknown audits, absent guardians or live on-chain risk-off",()=>{
 assert.equal(evaluateLaunch(checks,signals,policy).admitTrading,true);
 for(const changes of [{auditedConfiguration:false},{guardianConfigured:false},{riskIncreasePaused:true},
  {deploymentVerified:false},{canonicalStorageDurable:false}]){
  assert.equal(evaluateLaunch({...checks,...changes},signals,policy).admitTrading,false);
 }
 assert.throws(()=>requireLaunchReady({...checks,auditedConfiguration:false},signals,policy),/launch denied/);
});
test("untrusted truthy strings cannot authorize trading",()=>{
 assert.equal(evaluateLaunch({...checks,guardianConfigured:"true"},signals,policy).admitTrading,false);
 assert.equal(evaluateLaunch(checks,{...signals,rpcWitnessesAgree:"true"},policy).admitTrading,false);
});
test("unsafe oracle stops risk growth but verified deployment retains cancel/settle route",()=>{
 const decision=evaluateLaunch(checks,{...signals,sequencerUp:false},policy);
 assert.equal(decision.admitTrading,false);assert.equal(decision.admitRiskReduction,true);
});

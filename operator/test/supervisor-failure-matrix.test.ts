import test from "node:test";
import assert from "node:assert/strict";
import { createOperatorSupervisor } from "../dist/supervisor.js";
import { createRecoveryPublication } from "../dist/publication.js";

const ADDRESS = "0x1111111111111111111111111111111111111111";
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 1,
  collateral: { token: ADDRESS, decimals: 18 },
  markets: [{ id: "ETH-PERP", core: ADDRESS, advanced: ADDRESS, oracle: ADDRESS }] };

function deferred() {
  let release;
  const promise = new Promise(resolve => { release = resolve; });
  return { promise, release };
}
function setup() {
  let chainId = 1, storageFail = false, nextBlockFail = false, writes = 0;
  let checkpoint;
  const rpc = {
    getChainId: async () => chainId,
    getHeadBlockNumber: async () => { if (nextBlockFail) throw new Error("RPC failure"); return 1; },
    getBlock: async () => ({ number: 1, hash: "0x001", parentHash: "0x000" }),
    getEvents: async () => [],
    getMarkTicks: async () => ({})
  };
  const store = { load: async () => checkpoint, save: async (_, state) => {
    if (storageFail) throw new Error("disk unavailable");
    checkpoint = state; writes++;
  } };
  const publication = createRecoveryPublication(manifest, rpc, store);
  return { publication, setChainId: id => {chainId=id;}, setStorageFailure: x => {storageFail=x;},
    setRpcFailure: x=>{nextBlockFail=x;}, get writes(){return writes;} };
}

test("supervisor rejects keeper work during RPC failure and recovers after canonical replay", async () => {
  const h=setup();
  const events=[];
  const first=deferred(), second=deferred(), third=deferred();
  const s=createOperatorSupervisor(h.publication, {intervalMs:5,maxBackoffMs:20,onCycle:event=>{
    events.push(event.kind);
    if(events.length===1)first.release();
    if(events.length===2)second.release();
    if(events.length===3)third.release();
  }});
  const running=s.run();
  try {
    await first.promise;
    assert.equal(s.status().ready,true);
    h.setRpcFailure(true);
    await second.promise;
    assert.equal(s.status().ready,false);
    await assert.rejects(s.submit([],{},{}),/not ready/);
    h.setRpcFailure(false);
    await third.promise;
    assert.equal(s.status().ready,true);
    assert.deepEqual(events.slice(0,3),["ready","error","ready"]);
  } finally {s.stop();await running;}
});
test("supervisor rejects wrong-chain reads, then re-admits only after recovery", async()=>{
  const h=setup();const events=[];const signals=[deferred(),deferred(),deferred()];
  const s=createOperatorSupervisor(h.publication,{intervalMs:5,maxBackoffMs:20,onCycle:e=>{
    events.push(e.kind);if(events.length<=3)signals[events.length-1].release();
  }});
  const running=s.run();
  try{
    await signals[0].promise;assert.equal(s.status().ready,true);
    h.setChainId(5);await signals[1].promise;
    assert.equal(s.status().ready,false);
    await assert.rejects(s.submit([],{},{}),/not ready/);
    h.setChainId(1);await signals[2].promise;
    assert.equal(s.status().ready,true);
  }finally{s.stop();await running;}
});
test("persist failure never reports a ready publication and recovers",async()=>{
  const h=setup();const signals=[deferred(),deferred(),deferred()];let cycles=0;
  const s=createOperatorSupervisor(h.publication,{intervalMs:5,maxBackoffMs:20,onCycle:()=>{
    cycles++;if(cycles<=3)signals[cycles-1].release();
  }});
  const running=s.run();
  try{
    await signals[0].promise;assert.equal(s.status().ready,true);
    h.setStorageFailure(true);await signals[1].promise;
    assert.equal(s.status().ready,false);
    await assert.rejects(s.submit([],{},{}),/not ready/);
    h.setStorageFailure(false);await signals[2].promise;
    assert.equal(s.status().ready,true);
  }finally{s.stop();await running;}
});

import test from "node:test";
import assert from "node:assert/strict";
import {mkdtemp,rm} from "node:fs/promises";
import {join} from "node:path";
import {tmpdir} from "node:os";
import {JsonSubmissionJournal} from "../dist/submission-journal.js";
test("persisted request idempotency survives restart and blocks replacement",async()=>{
 const dir=await mkdtemp(join(tmpdir(),"trade-journal-"));const path=join(dir,"jobs.json");
 try{
  const a=new JsonSubmissionJournal(path);
  await a.update({id:"A",fingerprint:"plan1",status:"reserved"});
  await a.update({id:"A",fingerprint:"plan1",status:"broadcast",txHash:"0x"+"a".repeat(64)});
  const b=new JsonSubmissionJournal(path);
  assert.equal((await b.load()).A.status,"broadcast");
  await assert.rejects(b.update({id:"A",fingerprint:"plan2",status:"reserved"}),/collision/);
  await b.update({id:"A",fingerprint:"plan1",status:"confirmed",txHash:"0x"+"a".repeat(64)});
  await assert.rejects(b.update({id:"A",fingerprint:"plan1",status:"broadcast",txHash:"0x"+"a".repeat(64)}),/cannot regress/);
 }finally{await rm(dir,{force:true,recursive:true})}
});

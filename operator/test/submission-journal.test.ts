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

test("rejects malformed hashes before writing and allows special request IDs",async()=>{
 const dir=await mkdtemp(join(tmpdir(),"trade-journal-"));const journal=new JsonSubmissionJournal(join(dir,"jobs.json"));
 try{
  await assert.rejects(journal.update({id:"bad",fingerprint:"p",status:"reserved",txHash:"oops"}),/invalid transaction hash/);
  await journal.update({id:"constructor",fingerprint:"p",status:"reserved"});
  await journal.update({id:"__proto__",fingerprint:"p",status:"reserved"});
  assert.equal((await journal.load()).constructor.id,"constructor");
  assert.equal((await journal.load())["__proto__"].id,"__proto__");
 }finally{await rm(dir,{force:true,recursive:true})}
});

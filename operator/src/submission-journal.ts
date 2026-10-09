import { open, readFile, rename, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
export interface SubmissionRecord {
  id: string; fingerprint: string; txHash?: string;
  status: "reserved" | "broadcast" | "confirmed" | "reverted" | "unknown";
}
export class JsonSubmissionJournal {
  private tail: Promise<unknown> = Promise.resolve();
  constructor(readonly path: string) { if (!path) throw new Error("journal path required"); }
  async load(): Promise<Readonly<Record<string, SubmissionRecord>>> {
    let raw: string;
    try { raw = await readFile(this.path, "utf8"); }
    catch (e) {if ((e as NodeJS.ErrnoException).code === "ENOENT") return {};throw e;}
    const items = JSON.parse(raw) as Record<string,SubmissionRecord>;
    if (!items || typeof items!=="object" || Array.isArray(items)) throw new Error("invalid transaction journal");
    for(const [id,r] of Object.entries(items)){
      if(id!==r?.id || !r.fingerprint || !["reserved","broadcast","confirmed","reverted","unknown"].includes(r.status) ||
          (r.txHash!==undefined && !/^0x[0-9a-fA-F]{64}$/.test(r.txHash))) throw new Error("invalid transaction journal record");
    }
    return items;
  }
  private serialize<T>(work:()=>Promise<T>):Promise<T>{
    const op=this.tail.then(work,work);this.tail=op.then(()=>undefined,()=>undefined);return op;
  }
  async update(next:SubmissionRecord):Promise<SubmissionRecord>{
    if(!next.id.trim()||!next.fingerprint.trim()|| !["reserved","broadcast","confirmed","reverted","unknown"].includes(next.status))
      throw new Error("invalid transaction record");
    return this.serialize(async()=>{
      const records={...await this.load()},previous=records[next.id];
      if(previous && previous.fingerprint!==next.fingerprint)throw new Error("idempotency collision");
      if(previous && ["confirmed","reverted"].includes(previous.status) && next.status!==previous.status)
        throw new Error("terminal transaction state cannot regress");
      if(previous?.txHash && previous.txHash!==next.txHash)throw new Error("transaction hash mismatch");
      if(next.status==="broadcast" && !/^0x[0-9a-fA-F]{64}$/.test(next.txHash??""))throw new Error("broadcast requires transaction hash");
      records[next.id]=next;
      const parent=resolve(dirname(this.path));await mkdir(parent,{recursive:true});
      const temp=this.path+"."+process.pid+"."+Date.now()+"."+Math.random().toString(36).slice(2)+".tmp";
      const fd=await open(temp,"wx",0o600);
      try {await fd.writeFile(JSON.stringify(records)+"\n");await fd.sync();}finally{await fd.close();}
      await rename(temp,this.path);
      const dir=await open(parent,"r");try{await dir.sync();}finally{await dir.close();}
      return next;
    });
  }
}

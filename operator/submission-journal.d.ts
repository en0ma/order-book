export interface SubmissionRecord {id:string;fingerprint:string;txHash?:string;status:"reserved"|"broadcast"|"confirmed"|"reverted"|"unknown"}
export declare class JsonSubmissionJournal {readonly path:string;constructor(path:string);load():Promise<Readonly<Record<string,SubmissionRecord>>>;update(next:SubmissionRecord):Promise<SubmissionRecord>}

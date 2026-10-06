import type { OperatorCheckpoint, OperatorCheckpointStore } from "./index.js";

export declare class JsonFileCheckpointStore implements OperatorCheckpointStore {
  readonly path: string;
  constructor(path: string);
  load(manifestIdentity: string): Promise<OperatorCheckpoint | undefined>;
  save(manifestIdentity: string, checkpoint: OperatorCheckpoint): Promise<void>;
}

export interface OperatorAuditRecord {
  timestamp: string;
  manifestIdentity: string;
  kind: "cycle" | "submission" | "error";
  payload: Record<string, unknown>;
}
export declare class JsonlOperatorAuditJournal {
  readonly path: string;
  constructor(path: string);
  append(record: OperatorAuditRecord): Promise<void>;
}

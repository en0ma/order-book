import type { OperatorCheckpoint, OperatorCheckpointStore } from "./index.js";

export declare class JsonFileCheckpointStore implements OperatorCheckpointStore {
  readonly path: string;
  constructor(path: string);
  load(manifestIdentity: string): Promise<OperatorCheckpoint | undefined>;
  save(manifestIdentity: string, checkpoint: OperatorCheckpoint): Promise<void>;
}

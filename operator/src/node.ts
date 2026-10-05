import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { OperatorCheckpoint, OperatorCheckpointStore } from "./index.js";

export class JsonFileCheckpointStore implements OperatorCheckpointStore {
  readonly path: string;

  constructor(path: string) {
    if (!path) throw new TypeError("checkpoint path is required");
    this.path = path;
  }

  async load(manifestIdentity: string): Promise<OperatorCheckpoint | undefined> {
    let raw: string;
    try {
      raw = await readFile(this.path, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    }
    const envelope = JSON.parse(raw) as {
      manifestIdentity?: string;
      checkpoint?: OperatorCheckpoint;
    };
    if (
      envelope.manifestIdentity !== manifestIdentity
      || !envelope.checkpoint
    ) {
      throw new Error("checkpoint file does not match manifest identity");
    }
    return envelope.checkpoint;
  }

  async save(
    manifestIdentity: string,
    checkpoint: OperatorCheckpoint,
  ): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const temp = `${this.path}.${process.pid}.tmp`;
    const payload = JSON.stringify(
      { manifestIdentity, checkpoint },
      null,
      2,
    ) + "\n";
    await writeFile(temp, payload, { encoding: "utf8", mode: 0o600 });
    await rename(temp, this.path);
  }
}

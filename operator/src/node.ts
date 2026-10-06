import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
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


function jsonSafe(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .map(([key, item]) => [key, jsonSafe(item)]),
    );
  }
  return value;
}

export interface OperatorAuditRecord {
  timestamp: string;
  manifestIdentity: string;
  kind: "cycle" | "submission" | "error";
  payload: Record<string, unknown>;
}

export class JsonlOperatorAuditJournal {
  readonly path: string;

  constructor(path: string) {
    if (!path) throw new TypeError("audit journal path is required");
    this.path = path;
  }

  async append(record: OperatorAuditRecord): Promise<void> {
    if (!record.manifestIdentity) throw new TypeError("manifestIdentity is required");
    if (!/^\d{4}-\d{2}-\d{2}T/.test(record.timestamp)) {
      throw new TypeError("timestamp must be ISO-8601");
    }
    await mkdir(dirname(this.path), { recursive: true });
    await appendFile(this.path, JSON.stringify(jsonSafe(record)) + "\n", {
      encoding: "utf8",
      mode: 0o600,
    });
  }
}

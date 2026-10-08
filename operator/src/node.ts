import { appendFile, mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { OperatorCheckpoint, OperatorCheckpointStore } from "./index.js";
import type { RecoveryBundle, RecoveryStore } from "./recovery.js";

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

/** Atomic whole-bundle store for one operator process. The path is not shared by writers. */
export class JsonFileRecoveryStore implements RecoveryStore {
  readonly path: string;
  private writes: Promise<void> = Promise.resolve();

  constructor(path: string) {
    if (!path) throw new TypeError("recovery bundle path is required");
    this.path = path;
  }

  async load(identity: string): Promise<RecoveryBundle | undefined> {
    let raw: string;
    try {
      raw = await readFile(this.path, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    }
    const envelope = JSON.parse(raw) as { identity?: string; bundle?: RecoveryBundle };
    if (envelope.identity !== identity || !envelope.bundle ||
        envelope.bundle.identity !== identity) {
      throw new Error("recovery file deployment identity mismatch");
    }
    return envelope.bundle;
  }

  save(identity: string, bundle: RecoveryBundle): Promise<void> {
    if (!identity || bundle.identity !== identity) {
      return Promise.reject(new Error("recovery bundle identity mismatch"));
    }
    const write = async () => {
      await mkdir(dirname(this.path), { recursive: true });
      const temp = this.path + "." + process.pid + "." +
        Date.now().toString(36) + "." + Math.random().toString(36).slice(2) + ".tmp";
      try {
        const handle = await open(temp, "wx", 0o600);
        try {
          await handle.writeFile(JSON.stringify({ identity, bundle }) + "\\n", "utf8");
          await handle.sync();
        } finally { await handle.close(); }
        await rename(temp, this.path);
        const directory = await open(dirname(this.path), "r");
        try { await directory.sync(); } finally { await directory.close(); }
      } finally {
        await rm(temp, { force: true });
      }
    };
    const operation = this.writes.then(write, write);
    this.writes = operation.then(() => undefined, () => undefined);
    return operation;
  }
}

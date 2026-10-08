import { link, open, unlink } from "node:fs/promises";
import { dirname } from "node:path";
import { randomUUID } from "node:crypto";
import { JsonFileRecoveryStore } from "./node.js";
import { validateRecoveryBundle } from "./recovery.js";
import { operatorManifestIdentity, validateOperatorManifest, type OperatorRpcAdapter } from "./index.js";

export interface RebuildApproval {
  /** Exact persisted checkpoint block. Prevents accidentally retiring another checkpoint. */
  checkpointNumber: number;
  checkpointHash: string;
  /** Hash observed from an independent, trusted canonical RPC source. */
  canonicalHash: string;
}
export interface RebuildPreparation {
  archivedPath: string;
  rejectedHead: { number: number; hash: string };
  observedCanonicalHash: string;
}

/**
 * Explicit cold-start recovery for a confirmed orphaned checkpoint.
 * Call only while the operator and all other writers are stopped.
 * Creates a non-overwriting archive before unlinking the live bundle.
 */
export async function quarantineOrphanedRecovery(
  manifestInput: unknown, rpc: OperatorRpcAdapter, bundlePath: string,
  approval: RebuildApproval,
): Promise<RebuildPreparation> {
  const manifest = validateOperatorManifest(manifestInput);
  if (await rpc.getChainId() !== manifest.chainId) {
    throw new Error("rebuild rejected: RPC chain ID mismatch");
  }
  const identity = operatorManifestIdentity(manifest);
  const bundle = await new JsonFileRecoveryStore(bundlePath).load(identity);
  if (!bundle) throw new Error("rebuild rejected: no recovery bundle");
  validateRecoveryBundle(manifest, bundle);
  const checkpoint = bundle.checkpoint.head;
  if (!checkpoint || !Number.isSafeInteger(approval?.checkpointNumber) ||
      approval.checkpointNumber !== checkpoint.number ||
      approval.checkpointHash !== checkpoint.hash ||
      typeof approval.canonicalHash !== "string") {
    throw new Error("rebuild rejected: checkpoint approval mismatch");
  }
  const canonical = await rpc.getBlock(checkpoint.number);
  if (canonical.number !== checkpoint.number ||
      canonical.hash.toLowerCase() !== approval.canonicalHash.toLowerCase()) {
    throw new Error("rebuild rejected: canonical approval mismatch");
  }
  if (canonical.hash.toLowerCase() === checkpoint.hash.toLowerCase()) {
    throw new Error("rebuild rejected: checkpoint is already canonical");
  }
  const archive = bundlePath + ".orphan-" + randomUUID();
  // A hard link cannot overwrite an existing path. Keep the archival bytes intact.
  await link(bundlePath, archive);
  const parent = await open(dirname(bundlePath), "r");
  try {
    await parent.sync(); // Archive entry is durable before any destructive operation.
    // Revalidate after archive creation. A changing branch cannot authorize a reset.
    if (await rpc.getChainId() !== manifest.chainId ||
        (await rpc.getBlock(checkpoint.number)).hash.toLowerCase() !==
          approval.canonicalHash.toLowerCase()) {
      throw new Error("rebuild rejected: canonical branch changed during approval");
    }
    await unlink(bundlePath);
    await parent.sync();
  } finally {
    await parent.close();
  }
  return {
    archivedPath: archive,
    rejectedHead: { number: checkpoint.number, hash: checkpoint.hash },
    observedCanonicalHash: canonical.hash,
  };
}

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSelfHostedOperator } from "../dist/self-hosted.js";
import { quarantineOrphanedRecovery } from "../dist/rebuild.js";
const addr = "0x1111111111111111111111111111111111111111";
const H0 = "0x000", H1 = "0x001", HF = "0x999";
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 1,
  collateral: { token: addr, decimals: 18 },
  markets: [{ id: "ETH", core: addr, advanced: addr, oracle: addr }] };
function rpc(hash = H1) {
  return { getChainId: async () => 1, getHeadBlockNumber: async () => 1,
    getBlock: async number => ({ number, hash, parentHash: H0 }),
    getEvents: async () => [], getMarkTicks: async () => ({}) };
}
test("manual approval archives orphaned Core+strategy bundle before fresh replay", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-rebuild-"));
  const path = join(dir, "bundle.json");
  try {
    const old = createSelfHostedOperator(manifest, rpc(H1), { bundlePath: path });
    await old.recover();
    const saved = await readFile(path, "utf8");
    const fork = rpc(HF);
    const rejected = createSelfHostedOperator(manifest, fork, { bundlePath: path });
    await assert.rejects(rejected.recover(), /not on the canonical branch/);
    assert.equal(rejected.publication.ready(), false);
    await assert.rejects(quarantineOrphanedRecovery(manifest, fork, path, {
      checkpointNumber: 1, checkpointHash: H1, canonicalHash: "0xwrong",
    }), /canonical approval mismatch/);
    assert.equal(await readFile(path, "utf8"), saved);
    const result = await quarantineOrphanedRecovery(manifest, fork, path, {
      checkpointNumber: 1, checkpointHash: H1, canonicalHash: HF,
    });
    assert.equal(result.rejectedHead.hash, H1);
    assert.equal(await readFile(result.archivedPath, "utf8"), saved);
    await assert.rejects(readFile(path, "utf8"), { code: "ENOENT" });
    const rebuilt = createSelfHostedOperator(manifest, fork, { bundlePath: path });
    const recovery = await rebuilt.recover();
    assert.equal(recovery.restored, false);
    assert.equal(recovery.head.hash, HF);
    assert.equal(rebuilt.publication.ready(), true);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
test("canonical checkpoint and wrong chain cannot be quarantined", async () => {
  const dir = await mkdtemp(join(tmpdir(), "ob-rebuild-"));
  const path = join(dir, "bundle.json");
  try {
    await createSelfHostedOperator(manifest, rpc(), { bundlePath: path }).recover();
    const before = await readFile(path, "utf8");
    await assert.rejects(quarantineOrphanedRecovery(manifest, rpc(), path, {
      checkpointNumber: 1, checkpointHash: H1, canonicalHash: H1,
    }), /already canonical/);
    const wrong = rpc(HF);
    wrong.getChainId = async () => 2;
    await assert.rejects(quarantineOrphanedRecovery(manifest, wrong, path, {
      checkpointNumber: 1, checkpointHash: H1, canonicalHash: HF,
    }), /chain ID mismatch/);
    assert.equal(await readFile(path, "utf8"), before);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const outputDir = resolve(here, "dist");
await mkdir(outputDir, { recursive: true });

for (const entry of ["index", "node", "integration", "api", "strategies", "read-model", "http", "readiness", "recovery", "recovery-cycle", "publication", "self-hosted", "supervisor", "rpc-adapter"]) {
  const sourcePath = resolve(here, `src/${entry}.ts`);
  const outputPath = resolve(outputDir, `${entry}.js`);
  const source = await readFile(sourcePath, "utf8");
  const output = stripTypeScriptTypes(source, {
    mode: "strip",
    sourceMap: false,
  });
  await writeFile(
    outputPath,
    `// Generated from src/${entry}.ts by build.mjs. Do not edit directly.\n${output}`,
  );
}

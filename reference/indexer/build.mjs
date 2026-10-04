import { mkdir, readFile, writeFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const sourcePath = resolve(here, "src/index.ts");
const outputDir = resolve(here, "dist");
const outputPath = resolve(outputDir, "index.js");

const source = await readFile(sourcePath, "utf8");
const output = stripTypeScriptTypes(source, { mode: "strip", sourceMap: false });

await mkdir(outputDir, { recursive: true });
await writeFile(
  outputPath,
  "// Generated from src/index.ts by build.mjs. Do not edit directly.\n" + output,
);

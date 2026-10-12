#!/usr/bin/env node
// Conservative inventory: all source reachability signals, never a deletion verdict.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, extname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const files = execFileSync("git", ["ls-files", "-z"], { cwd: root }).toString().split("\0").filter(Boolean).sort();
const paths = new Set(files);
const read = (p) => readFileSync(resolve(root, p), "utf8");
const code = files.filter((p) => /\.(?:sol|ts|mjs|js)$/.test(p) && !/\.d\.ts$/.test(p));
const graph = new Map(code.map((p) => [p, new Set()]));
const inbound = new Map(code.map((p) => [p, new Set()]));
const resolveImport = (from, imp) => {
  if (!imp.startsWith(".")) return null;
  const base = resolve(root, dirname(from), imp);
  const choices = [base, base + ".sol", base + ".ts", base + ".mjs", base + ".js", base.replace(/\.js$/, ".ts")];
  return choices.map((v) => relative(root, v).replaceAll("\\", "/")).find((v) => paths.has(v)) || null;
};
for (const path of code) {
  const text = read(path);
  const patterns = [/(?:import|export)\s+(?:[^;"']+?\s+from\s+)?["']([^"']+)["']/g, /import\s*\(\s*["']([^"']+)["']\s*\)/g, /import\s+[^;]+?\s+from\s+["']([^"']+)["']/g];
  for (const pattern of patterns) {
    for (const match of text.matchAll(pattern)) {
      const dep = resolveImport(path, match[1]);
      if (dep && graph.has(dep)) { graph.get(path).add(dep); inbound.get(dep).add(path); }
    }
  }
}
const source = code.filter((p) => p.startsWith("src/") || p.startsWith("operator/src/") || p.startsWith("sdk/src/") || p.startsWith("reference/indexer/src/"));
const tests = code.filter((p) => p.startsWith("test/") || p.startsWith("test-js/") || /\/test\//.test(p));
const roots = new Set([...tests, ...code.filter((p) => p.startsWith("script/"))]);
for (const base of ["operator", "sdk", "reference/indexer"]) {
  const pkgFile = base + "/package.json";
  if (!paths.has(pkgFile)) continue;
  const pkg = JSON.parse(read(pkgFile));
  for (const key of Object.keys(pkg.exports || {})) {
    const leaf = key === "." ? "index" : key.slice(2);
    const p = base + "/src/" + leaf + ".ts";
    if (paths.has(p)) roots.add(p);
  }
}
for (const entry of ["src/deployable/OrderBookCore.sol", "src/deployable/AdvancedOrderModule.sol", "src/deployable/MarketMakerModule.sol", "src/deployable/LiquidationModule.sol", "src/deployable/PortfolioAdmissionCoordinator.sol", "src/ProRataOrderBook.sol"]) {
  if (paths.has(entry)) roots.add(entry);
}
const reachable = new Set(roots);
const pending = [...roots];
while (pending.length) for (const child of graph.get(pending.pop()) || []) if (!reachable.has(child)) { reachable.add(child); pending.push(child); }

const isolated = source.filter((p) => !reachable.has(p));
const docs = files.filter((p) => /^docs\/.*\.mdx?$/.test(p));
const nav = paths.has("docs.json") ? JSON.parse(read("docs.json")) : {};
const navPages = new Set((nav.navigation?.groups || []).flatMap((g) => g.pages || []).map((p) => p.replace(/\.(md|mdx)$/, "")));
const docsNotNav = docs.filter((p) => !navPages.has(p.replace(/\.(md|mdx)$/, "")));
const generated = files.filter((p) => /(^|\/)(dist|out|cache|node_modules)\//.test(p) || /(^|\/)coverage\//.test(p));
const fileRefs = new Map(docs.map((p) => [p, new Set()]));
for (const from of files.filter((p) => /\.(?:md|mdx|json)$/.test(p))) {
  const content = read(from);
  for (const target of docs) {
    const name = target.split("/").at(-1);
    if (from !== target && (content.includes(target) || content.includes(name) || content.includes("/" + target.replace(/\.mdx?$/, "")))) fileRefs.get(target).add(from);
  }
}
const docsNoInbound = docsNotNav.filter((p) => fileRefs.get(p).size === 0);
const result = {
  trackedFiles: files.length, sourceFiles: source.length, testFiles: tests.length,
  importEdges: [...graph.values()].reduce((n, edges) => n + edges.size, 0),
  sourceNotReachedFromKnownRoots: isolated,
  trackedBuildOutput: generated,
  docsOutsideMintlifyNavigation: docsNotNav,
  docsOutsideNavigationWithNoExactFilenameReference: docsNoInbound,
  notes: [
    "Source reachability depends on declared roots and static imports; dynamic access and external integrations are not visible.",
    "A public Solidity contract or package export is not dead even when it has no internal importer.",
    "Not present in Mintlify navigation is not evidence that a technical reference is obsolete.",
    "Do not delete any candidate without a manual ABI/export, release, and CI review."
  ]
};
if (process.argv.includes("--json")) console.log(JSON.stringify(result, null, 2));
else {
  console.log("Tracked files:", result.trackedFiles, "source files:", result.sourceFiles, "test files:", result.testFiles, "import edges:", result.importEdges);
  for (const key of ["sourceNotReachedFromKnownRoots","trackedBuildOutput","docsOutsideMintlifyNavigation","docsOutsideNavigationWithNoExactFilenameReference"]) {
    console.log("\n" + key + " (" + result[key].length + ")");
    result[key].forEach((p) => console.log(" - " + p));
  }
  result.notes.forEach((n) => console.log("NOTE:", n));
}

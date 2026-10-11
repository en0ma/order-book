#!/usr/bin/env node
// Check that the Mintlify navigation and local Markdown assets resolve in this repo.
// This check has no network access and does not claim to validate external URLs or rendering.
import {existsSync, readFileSync} from "node:fs";
import {dirname, extname, resolve} from "node:path";
import {fileURLToPath} from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const errors = [];
const site = JSON.parse(readFileSync(resolve(root, "docs.json"), "utf8"));
const pages = site.navigation?.groups?.flatMap((g) => g.pages || []) || [];
const checked = new Set();
function checkPage(raw, source) {
  if (/^(https?:|mailto:|#)/.test(raw)) return;
  const path = raw.split("#")[0].split("?")[0];
  if (!path) return;
  const target = resolve(source, decodeURIComponent(path));
  const options = extname(target) ? [target] : [target, target + ".md", target + ".mdx", resolve(target,"index.md"), resolve(target,"index.mdx")];
  if (!options.some(existsSync)) errors.push(`Missing local resource: ${raw} (from ${source})`);
}
for (const page of pages) {
  if (typeof page !== "string") continue;
  const options = [resolve(root, page+".md"),resolve(root,page+".mdx"),resolve(root,page)];
  const path = options.find(existsSync);
  if (!path) { errors.push(`Mintlify navigation page missing: ${page}`); continue; }
  checked.add(path);
}
for (const path of checked) {
  const content = readFileSync(path, "utf8");
  // Markdown links and local images; external links are intentionally excluded.
  const pattern = /!?\[[^\]]*\]\(([^)]+)\)/g;
  for (const match of content.matchAll(pattern)) {
    const link = match[1].split(/\s+"/)[0].trim().replace(/^<|>$/g,"");
    checkPage(link, dirname(path));
  }
}
if (errors.length) {
  for (const err of errors) console.error(err);
  process.exitCode = 1;
} else {
  console.log(`Navigation and relative links resolved for ${checked.size} Mintlify pages.`);
}

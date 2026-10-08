#!/usr/bin/env node
import { readFileSync } from "node:fs";

const BOROS_SOURCE = "78403bfe26d9a4c2cf8121726f4d6d9c1539009c";
const protocols = ["order-book", "boros"];
function fail(message) { throw new Error("comparison rejected: " + message); }
const positiveInt = n => Number.isSafeInteger(n) && n > 0;
const signature = row => [row.makers, row.ticks, row.postedLots, row.filledLots,
  row.fillPolicy, row.gasEnvironment].join("|");

/** Compare measured, externally supplied results; never invent Boros gas. */
export function compareEvidence(inputs) {
  if (!Array.isArray(inputs) || inputs.length !== 2 ||
      protocols.some(p => !inputs.some(i => i?.protocol === p))) fail("supply both protocol measurements");
  for (const input of inputs) {
    if (!/^[0-9a-f]{40}$/.test(input.commit || "") || !input.source ||
        !input.compiler || !input.evm || !input.optimizer ||
        !Array.isArray(input.rows) || input.rows.length === 0) {
      fail("missing source revision, compiler, environment, or measurements for " + input.protocol);
    }
    if (input.protocol === "boros" && input.commit !== BOROS_SOURCE) {
      fail("Boros revision must match the pinned and reviewed source");
    }
    const keys = new Set();
    for (const r of input.rows) {
      if (![r.makers, r.ticks, r.postedLots, r.filledLots, r.gasUsed].every(positiveInt)
          || r.filledLots > r.postedLots || !r.fillPolicy || !r.gasEnvironment) {
        fail("incomplete or invalid workload for " + input.protocol);
      }
      const key = signature(r);
      if (keys.has(key)) fail("duplicate workload for " + input.protocol);
      keys.add(key);
    }
  }
  const [ours, boros] = protocols.map(name => inputs.find(x => x.protocol === name));
  if (ours.evm !== boros.evm || ours.optimizer !== boros.optimizer) {
    fail("EVM or optimizer conditions differ");
  }
  if (ours.compiler !== boros.compiler) {
    fail("compiler versions differ; disclose differences before making a matched comparison");
  }
  const theirRows = new Map(boros.rows.map(r => [signature(r), r]));
  if (ours.rows.length !== boros.rows.length) fail("different number of workloads");
  return ours.rows.map(row => {
    const theirs = theirRows.get(signature(row));
    if (!theirs) fail("unmatched workload: " + signature(row));
    return { makers: row.makers, ticks: row.ticks, postedLots: row.postedLots,
      filledLots: row.filledLots, oursGas: row.gasUsed, borosGas: theirs.gasUsed,
      deltaGas: row.gasUsed - theirs.gasUsed };
  });
}
export function toMarkdown(rows) {
  return ["| Makers | Ticks | Posted lots | Filled lots | Our gas | Boros gas | Delta (ours - Boros) |",
    "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ...rows.map(r => `| ${r.makers} | ${r.ticks} | ${r.postedLots} | ${r.filledLots} | ${r.oursGas} | ${r.borosGas} | ${r.deltaGas} |`)].join("\n");
}
if (process.argv[1] && import.meta.url === new URL("file://" + process.argv[1]).href) {
  try {
    if (process.argv.length !== 4) fail("usage: node script/compare_boros.mjs ours.json boros.json");
    const inputs = process.argv.slice(2).map(path => JSON.parse(readFileSync(path, "utf8")));
    process.stdout.write(toMarkdown(compareEvidence(inputs)) + "\n");
  } catch (error) {
    process.stderr.write(String(error.message) + "\n");
    process.exitCode = 1;
  }
}

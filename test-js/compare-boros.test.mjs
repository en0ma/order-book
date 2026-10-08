import test from "node:test";
import assert from "node:assert/strict";
import { compareEvidence, toMarkdown } from "../script/compare_boros.mjs";

const BOROS = "78403bfe26d9a4c2cf8121726f4d6d9c1539009c";
const OURS = "9841916a423039138c18dd35462e43e94d9d77c6";
function sample(protocol) {
  return {
    protocol, source: "github", commit: protocol === "boros" ? BOROS : OURS,
    compiler: "0.8.28", evm: "cancun", optimizer: "100000",
    rows: [{ makers: 8, ticks: 2, postedLots: 1600, filledLots: 1600,
      fillPolicy: "IOC", gasEnvironment: "cold-transaction",
      gasUsed: protocol === "boros" ? 120000 : 100000 }],
  };
}
test("renders deltas only for complete equivalent evidence", () => {
  const rows = compareEvidence([sample("order-book"), sample("boros")]);
  assert.equal(rows[0].deltaGas, -20000);
  assert.match(toMarkdown(rows), /-20000/);
});
test("refuses a one-sided or unverifiable competitive gas claim", () => {
  assert.throws(() => compareEvidence([sample("order-book")]), /both protocol/);
  const alternate = sample("boros");
  alternate.commit = "f".repeat(40);
  assert.throws(() => compareEvidence([sample("order-book"), alternate]), /pinned/);
});
test("refuses unequal maker count, fill quantity, and compiler environments", () => {
  for (const field of ["makers", "ticks", "postedLots", "filledLots", "gasEnvironment"]) {
    const theirs = sample("boros");
    theirs.rows[0][field] = field === "gasEnvironment" ? "warm" : theirs.rows[0][field] + 1;
    assert.throws(() => compareEvidence([sample("order-book"), theirs]), /unmatched|invalid/);
  }
  const differentCompiler = sample("boros");
  differentCompiler.compiler = "0.8.24";
  assert.throws(() => compareEvidence([sample("order-book"), differentCompiler]), /compiler versions/);
});
test("rejects duplicate, invalid and misaligned workloads", () => {
  const theirs = sample("boros");
  theirs.rows.push({ ...theirs.rows[0] });
  assert.throws(() => compareEvidence([sample("order-book"), theirs]), /duplicate/);
  const bad = sample("order-book");
  bad.rows[0].filledLots = 1700;
  assert.throws(() => compareEvidence([bad, sample("boros")]), /invalid workload/);
});

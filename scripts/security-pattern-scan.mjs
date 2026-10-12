#!/usr/bin/env node
// Heuristic Solidity triage, not a substitute for a contract security audit.
import {execFileSync} from "node:child_process";
import {readFileSync} from "node:fs";
import {stripSolidityCommentsAndStrings} from "./solidity-lexical-mask.mjs";

const files=execFileSync("git",["ls-files","src/**/*.sol","src/*.sol","script/*.sol"],{encoding:"utf8"}).trim().split("\n").filter(x=>x.endsWith(".sol"));
const review=[
  ["UNSAFE-DELEGATECALL", /\bdelegatecall\b/g],
  ["DESTROY", /\bselfdestruct\b|\bsuicide\s*\(/g],
  ["ARBITRARY-CALL", /\.call\s*(?:\{|\()/g],
  ["ASSEMBLY", /\bassembly\s*\{/g],
  ["UNCHECKED-ARITHMETIC", /\bunchecked\s*\{/g],
  ["TOKEN-TRANSFER", /\.transferFrom\s*\(|\.transfer\s*\(/g],
  ["EXTERNAL-CONTRACT-READ", /\.balanceOf\s*\(/g]
];
const banned=/\btx\s*\.\s*origin\b/g;
let failures=0,matches=0;
for(const file of files){
  const source=stripSolidityCommentsAndStrings(readFileSync(file,"utf8"));
  for(const [id,re] of review){
    for(const match of source.matchAll(re)){
      matches++;
      console.log(`REVIEW ${id} ${file}:${source.slice(0,match.index).split("\n").length}`);
    }
  }
  for(const match of source.matchAll(banned)){
    matches++;failures++;
    console.log(`BLOCK AUTH-TXORIGIN ${file}:${source.slice(0,match.index).split("\n").length}`);
  }
}
console.log(`Scanned ${files.length} Solidity files; found ${matches} triage matches and ${failures} blocked patterns.`);
if(failures)process.exitCode=1;

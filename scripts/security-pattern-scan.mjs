#!/usr/bin/env node
// Report potentially dangerous EVM patterns; block only explicit high-signal banned primitives.
// This is a triage tool, NOT a security audit or proof of exploit absence.
import {execFileSync} from "node:child_process";
import {readFileSync} from "node:fs";
const files=execFileSync("git",["ls-files","src/**/*.sol","src/*.sol","script/*.sol"],{encoding:"utf8"}).trim().split("\n").filter(x=>x.endsWith(".sol"));
const patterns=[
  {id:"AUTH-TXORIGIN",re:/\btx\s*\.\s*origin\b/g,block:true},
  {id:"UNSAFE-DELEGATECALL",re:/\bdelegatecall\b/g,block:false},
  {id:"DESTROY",re:/\bselfdestruct\b|\bsuicide\s*\(/g,block:false},
  {id:"ARBITRARY-CALL",re:/\.call\s*(?:\{|\()/g,block:false},
  {id:"SEND-ETHER",re:/\.send\s*\(|\.transfer\s*\(/g,block:false},
  {id:"ASSEMBLY",re:/\bassembly\s*\{/g,block:false},
  {id:"UNCHECKED-ARITHMETIC",re:/\bunchecked\s*\{/g,block:false},
  {id:"TOKEN-TRANSFER",re:/\.transferFrom\s*\(|\.transfer\s*\(/g,block:false},
  {id:"EXTERNAL-CONTRACT-READ",re:/\.balanceOf\s*\(/g,block:false}
];
let failures=0,matches=0;
for(const file of files){
  const lines=readFileSync(file,"utf8").split("\n");
  for(let i=0;i<lines.length;i++){
    const line=lines[i].replace(/\/\/.*$/,"");
    for(const p of patterns){p.re.lastIndex=0;if(p.re.test(line)){matches++;console.log(`${p.block?"BLOCK":"REVIEW"} ${p.id} ${file}:${i+1}`);if(p.block)failures++;}}
  }
}
console.log(`Scanned ${files.length} Solidity files; found ${matches} triage matches and ${failures} blocked patterns.`);
if(failures){console.error("Unapproved tx.origin authorization risk. Review and remove the primitive.");process.exitCode=1;}

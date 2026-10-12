import test from "node:test";
import assert from "node:assert/strict";
import {stripSolidityCommentsAndStrings} from "../scripts/solidity-lexical-mask.mjs";
const banned=/\btx\s*\.\s*origin\b/;
test("detects cross-line and comment-separated tx.origin",()=>{
  for(const input of ["tx.origin","tx\n.origin","tx /* comment */ . origin","tx /*multi\nline*/ . /*x*/ origin"]){
    assert.match(stripSolidityCommentsAndStrings(input),banned,input);
  }
});
test("ignores comments and string text",()=>{
  for(const input of ["// tx.origin","/* tx.origin */",'string memory example = "tx.origin";',"'tx.origin'"]){
    assert.doesNotMatch(stripSolidityCommentsAndStrings(input),banned,input);
  }
});

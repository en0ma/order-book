import test from "node:test";
import assert from "node:assert/strict";
import {auditFeeBacking,planFeeAllocation,parseTokenUnits} from "../dist/accounting-audit.js";
const initial={tokenBalance:150n,localCollateral:100n,portfolioCollateral:0n,insuranceReserves:10n,protocolFeesAccrued:40n,otherReservedLiabilities:0n};
test("fee routing preserves collateral liabilities including insurance",()=>{
 assert.equal(auditFeeBacking(initial).excess,0n);
 const next=planFeeAllocation(initial,{toInsurance:25n,toRecipient:15n});
 assert.equal(next.insuranceReserves,35n);assert.equal(next.protocolFeesAccrued,0n);
 assert.equal(next.tokenBalance,135n);assert.equal(auditFeeBacking(next).excess,0n);
});
test("solvency and fee claims fail closed on underfunding and over-allocation",()=>{
 assert.throws(()=>auditFeeBacking({...initial,tokenBalance:149n}),/insufficient/);
 assert.throws(()=>planFeeAllocation(initial,{toInsurance:30n,toRecipient:20n}),/exceeds/);
});
test("integer decimal normalization rejects precision loss",()=>{
 assert.equal(parseTokenUnits("1.001",6),1001000n);
 assert.equal(parseTokenUnits("0",0),0n);
 assert.throws(()=>parseTokenUnits("1.0001",3),/precision/);
});

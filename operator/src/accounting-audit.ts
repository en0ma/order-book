/** Independent accounting checks for collateral and protocol fee operations.
 * Amounts are integer collateral token base units, never floats.
 */
export interface FeeLedger {
  tokenBalance: bigint;
  localCollateral: bigint;
  portfolioCollateral: bigint;
  insuranceReserves: bigint;
  protocolFeesAccrued: bigint;
  otherReservedLiabilities: bigint;
}
export interface FeeAllocation { toInsurance: bigint; toRecipient: bigint }
export function auditFeeBacking(ledger: FeeLedger): { liabilities: bigint; excess: bigint } {
 for (const [key,value] of (["tokenBalance", "localCollateral", "portfolioCollateral", "insuranceReserves", "protocolFeesAccrued", "otherReservedLiabilities"] as const).map(key => [key, ledger[key]] as const)) {
   if (typeof value !== "bigint" || value < 0n) throw new Error("invalid nonnegative collateral amount: "+key);
 }
 const liabilities=ledger.localCollateral + ledger.portfolioCollateral +
   ledger.insuranceReserves + ledger.protocolFeesAccrued + ledger.otherReservedLiabilities;
 if(ledger.tokenBalance < liabilities)throw new Error("insufficient token backing for declared liabilities");
 return {liabilities,excess:ledger.tokenBalance-liabilities};
}
export function planFeeAllocation(ledger: FeeLedger, allocation: FeeAllocation) {
 auditFeeBacking(ledger);
 if(typeof allocation.toInsurance!=="bigint" || typeof allocation.toRecipient!=="bigint" ||
   allocation.toInsurance < 0n || allocation.toRecipient < 0n ||
   allocation.toInsurance+allocation.toRecipient > ledger.protocolFeesAccrued) {
   throw new Error("fee allocation exceeds accrued fees");
 }
 const after={...ledger,protocolFeesAccrued:ledger.protocolFeesAccrued-allocation.toInsurance-allocation.toRecipient,
   insuranceReserves:ledger.insuranceReserves+allocation.toInsurance,
   tokenBalance:ledger.tokenBalance-allocation.toRecipient};
 auditFeeBacking(after);
 return after;
}
export function parseTokenUnits(decimal:string,decimals:number):bigint {
 if(!Number.isSafeInteger(decimals)||decimals<0||decimals>36)throw new RangeError("invalid token decimals");
 if(!/^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/.test(decimal))throw new Error("invalid decimal amount");
 const [whole,fraction=""]=decimal.split(".");
 if(fraction.length>decimals)throw new Error("precision exceeds token decimals");
 return BigInt(whole)*10n**BigInt(decimals)+BigInt(fraction.padEnd(decimals,"0")||"0");
}

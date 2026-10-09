export interface FeeLedger {tokenBalance:bigint;localCollateral:bigint;portfolioCollateral:bigint;insuranceReserves:bigint;protocolFeesAccrued:bigint;otherReservedLiabilities:bigint}
export interface FeeAllocation {toInsurance:bigint;toRecipient:bigint}
export declare function auditFeeBacking(ledger:FeeLedger):{liabilities:bigint;excess:bigint};
export declare function planFeeAllocation(ledger:FeeLedger,allocation:FeeAllocation):FeeLedger;
export declare function parseTokenUnits(decimal:string,decimals:number):bigint;

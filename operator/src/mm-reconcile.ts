/** MM target-state quote reconciliation; actual signatures/submission remain external. */
export interface MakerQuoteTarget { side: 0 | 1; tick: number; lots: bigint }
export interface MakerRiskLimits { maxLotsPerQuote: bigint; maxTotalLots: bigint; maxQuotes: number }
export interface QuoteDelta extends MakerQuoteTarget {}
export function reconcileMakerQuotes(
 current: readonly MakerQuoteTarget[], target: readonly MakerQuoteTarget[], limits: MakerRiskLimits,
): QuoteDelta[] {
 if (limits.maxLotsPerQuote <= 0n || limits.maxLotsPerQuote > (1n << 96n) - 1n || limits.maxTotalLots <= 0n ||
     !Number.isSafeInteger(limits.maxQuotes) || limits.maxQuotes < 1) throw new RangeError("invalid maker risk limits");
 const key=(q:MakerQuoteTarget)=>q.side+":"+q.tick;
 function collect(entries:readonly MakerQuoteTarget[], enforceTargetLimit:boolean) {
   const map=new Map<string,MakerQuoteTarget>();
   for(const q of entries) {
     if ((q.side!==0 && q.side!==1) || !Number.isSafeInteger(q.tick) || q.tick<0 || q.tick>65535 ||
         typeof q.lots!=="bigint" || q.lots<0n || (enforceTargetLimit && q.lots>limits.maxLotsPerQuote) || map.has(key(q))) {
       throw new Error("invalid or duplicate maker quote");
     }
     map.set(key(q),q);
   }
   return map;
 }
 const live=collect(current,false),desired=collect(target,true);
 if(desired.size>limits.maxQuotes)throw new Error("maker quote count limit exceeded");
 let total=0n;for(const q of desired.values())total+=q.lots;
 if(total>limits.maxTotalLots)throw new Error("maker total exposure limit exceeded");
 return [...new Set([...live.keys(),...desired.keys()])].map(k=>{
   const old=live.get(k),next=desired.get(k);
   if((old?.lots??0n)===(next?.lots??0n))return undefined;
   const q=next??old!;
   return {side:q.side,tick:q.tick,lots:next?.lots??0n};
 }).filter((q):q is QuoteDelta=>q!==undefined).sort((a,b)=>a.side-b.side||a.tick-b.tick);
}
export function createMakerQuoteController(limits:MakerRiskLimits) {
 let stopped=false;
 return {
   stop(){stopped=true;},
   resume(){stopped=false;},
   plan(current:readonly MakerQuoteTarget[],target:readonly MakerQuoteTarget[]) {
     if(stopped && target.some(q=>q.lots>0n))throw new Error("maker kill switch active");
     return reconcileMakerQuotes(current,stopped?[]:target,limits);
   },
   stopped:()=>stopped,
 };
}

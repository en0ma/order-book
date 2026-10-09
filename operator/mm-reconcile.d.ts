export interface MakerQuoteTarget {side:0|1;tick:number;lots:bigint}
export interface MakerRiskLimits {maxLotsPerQuote:bigint;maxTotalLots:bigint;maxQuotes:number}
export interface QuoteDelta extends MakerQuoteTarget {}
export declare function reconcileMakerQuotes(current:readonly MakerQuoteTarget[],target:readonly MakerQuoteTarget[],limits:MakerRiskLimits):QuoteDelta[];
export declare function createMakerQuoteController(limits:MakerRiskLimits):{stop():void;resume():void;plan(current:readonly MakerQuoteTarget[],target:readonly MakerQuoteTarget[]):QuoteDelta[];stopped():boolean};

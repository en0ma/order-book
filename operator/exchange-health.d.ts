export interface ExchangeSignals {canonicalHead:number;remoteHead:number;oldestOracleAgeMs:number;sequencerUp:boolean;keeperPending:number;oldestKeeperAgeMs:number;rpcWitnessesAgree:boolean;recoveryReady:boolean;signerAvailable:boolean}
export interface ExchangePolicy {maxHeadLag:number;maxOracleAgeMs:number;maxKeeperAgeMs:number;maxKeeperPending:number}
export interface ExchangeHealth {ready:boolean;blockers:string[];warnings:string[]}
export declare function assessExchangeHealth(signals:ExchangeSignals,policy:ExchangePolicy):ExchangeHealth;
export declare function createIncidentController():{open(reason:string):void;acknowledge():void;clear(health:ExchangeHealth):void;status():{active:boolean;reason:string|undefined;acknowledged:boolean}};

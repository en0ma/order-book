import type {OracleObservation} from "./trading-safety.js";
export interface OracleReadConfig {chainId:number;oracleAddress:string;maxAgeMs:number;sequencerRequired?:boolean}
export interface OracleReader {getChainId():Promise<number>;readObservation(oracleAddress:string,blockTag:"latest"):Promise<{tick:number;timestampSeconds:number;sequencerUp:boolean}>}
export declare function createVerifiedOracleReader(reader:OracleReader,config:OracleReadConfig):(nowMs:number)=>Promise<OracleObservation>;

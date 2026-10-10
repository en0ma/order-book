import type {ExchangeHealth,ExchangePolicy,ExchangeSignals} from "./exchange-health.js";
export interface LaunchChecks {deploymentVerified:boolean;chainIdMatches:boolean;auditedConfiguration:boolean;guardianConfigured:boolean;riskIncreasePaused:boolean;canonicalStorageDurable:boolean;writableSignerConfigured:boolean}
export interface LaunchDecision {admitTrading:boolean;admitRiskReduction:boolean;reasons:string[];health:ExchangeHealth}
export declare function evaluateLaunch(checks:LaunchChecks,signals:ExchangeSignals,policy:ExchangePolicy):LaunchDecision;
export declare function requireLaunchReady(checks:LaunchChecks,signals:ExchangeSignals,policy:ExchangePolicy):void;

import type { ApiSnapshot, OperatorDiagnostics } from "./api.js";
import type { StrategySnapshot } from "./strategies.js";
export interface ReadModel { snapshot: ApiSnapshot; strategies?: StrategySnapshot; diagnostics?: OperatorDiagnostics; }
export type ReadResponse = { status: number; body: unknown };
export type RouteQuery = Readonly<Record<string, string | undefined>>;
export declare function marketBook(model: ReadModel, marketId: string, depth?: number): {
  chainId: number; head?: ApiSnapshot["head"]; marketId: string; levels: ApiSnapshot["pools"];
};
export declare function accountView(model: ReadModel, account: string, limit?: number, cursor?: string): {
  account: string; strategies: { items: StrategySnapshot["records"]; nextCursor?: string };
  portfolioLock?: ApiSnapshot["portfolioLocks"][number];
};
export declare function routeRead(model: ReadModel, method: string, pathname: string, query?: RouteQuery, knownMarkets?: readonly string[]): ReadResponse;
export declare function composeReadModel(snapshot: ApiSnapshot, strategies?: StrategySnapshot, diagnostics?: OperatorDiagnostics): ReadModel;

import type { ApiSnapshot, OperatorDiagnostics } from "./api.js";
import type { StrategySnapshot } from "./strategies.js";

/** Transport-neutral, immutable JSON-safe reads for self-hosted HTTP/WebSocket adapters. */
export interface ReadModel {
  snapshot: ApiSnapshot;
  strategies?: StrategySnapshot;
  diagnostics?: OperatorDiagnostics;
}
export type ReadResponse = { status: number; body: unknown };
export type RouteQuery = Readonly<Record<string, string | undefined>>;

function positiveBound(value: string | undefined, fallback: number, maximum: number): number {
  if (value === undefined) return fallback;
  if (!/^[1-9][0-9]*$/.test(value)) throw new TypeError("invalid positive limit");
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n > maximum) throw new RangeError("limit exceeds maximum");
  return n;
}
function decodeKey(key: string): unknown[] | undefined {
  try {
    const data: unknown = JSON.parse(key);
    return Array.isArray(data) ? data : undefined;
  } catch {
    return undefined;
  }
}
function matchesMarket(key: string, marketId: string): boolean {
  const decoded = decodeKey(key);
  return decoded ? decoded[0] === marketId : key.startsWith(marketId + ":");
}
function isAddress(account: string): boolean {
  return /^0x[0-9a-fA-F]{40}$/.test(account);
}
function collect<T extends { key: string }>(
  records: readonly T[], limit: number, cursor?: string,
): { items: T[]; nextCursor?: string } {
  if (cursor !== undefined && cursor.length > 512) throw new RangeError("cursor too long");
  const ordered = [...records].sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
  const start = cursor === undefined ? 0 : ordered.findIndex((r) => r.key > cursor);
  if (start === -1) return { items: [] };
  const items = ordered.slice(start, start + limit);
  return {
    items,
    ...(start + limit < ordered.length && items.length
      ? { nextCursor: items[items.length - 1].key } : {}),
  };
}
export function marketBook(
  model: ReadModel, marketId: string, depth = 25,
): { chainId: number; head?: ApiSnapshot["head"]; marketId: string; levels: ApiSnapshot["pools"] } {
  if (!Number.isSafeInteger(depth) || depth < 1 || depth > 100) {
    throw new RangeError("book depth must be 1..100");
  }
  const pool = model.snapshot.pools
    .filter((p) => matchesMarket(p.key, marketId) && BigInt(p.remainingLots) > 0n);
  const levelSide = (key: string) => Number(key.split(":").at(-2));
  const levelTick = (key: string) => Number(key.split(":").at(-1));
  const ranked = (side: number) => pool.filter((p) => levelSide(p.key) === side)
    .sort((a, b) => side === 0 ? levelTick(b.key) - levelTick(a.key) : levelTick(a.key) - levelTick(b.key))
    .slice(0, depth);
  const levels = [...ranked(0), ...ranked(1)];
  return { chainId: model.snapshot.chainId, ...(model.snapshot.head ? { head: model.snapshot.head } : {}),
    marketId, levels };
}
export function accountView(
  model: ReadModel, account: string, limit = 50, cursor?: string,
): { account: string; strategies: ReturnType<typeof collect<StrategySnapshot["records"][number]>>;
    portfolioLock?: ApiSnapshot["portfolioLocks"][number] } {
  if (!isAddress(account)) throw new TypeError("invalid account address");
  const strategies = (model.strategies?.records ?? [])
    .filter((r) => r.owner.toLowerCase() === account.toLowerCase());
  return {
    account: account.toLowerCase(),
    strategies: collect(strategies, limit, cursor),
    ...(model.snapshot.portfolioLocks.find((r) => r.account.toLowerCase() === account.toLowerCase())
      ? { portfolioLock: model.snapshot.portfolioLocks.find((r) =>
          r.account.toLowerCase() === account.toLowerCase()) } : {}),
  };
}
export function routeRead(
  model: ReadModel,
  method: string,
  pathname: string,
  query: RouteQuery = {},
  knownMarkets?: readonly string[],
): ReadResponse {
  if (method !== "GET") return { status: 405, body: { error: "method_not_allowed" } };
  try {
    if (pathname === "/health") {
      return { status: model.diagnostics?.status === "stalled" ? 503 : 200,
        body: model.diagnostics ?? { status: "unavailable", head: model.snapshot.head } };
    }
    if (pathname === "/markets") {
      const markets = knownMarkets ?? [];
      return { status: 200, body: { chainId: model.snapshot.chainId, markets: [...markets] } };
    }
    const book = /^\/markets\/([^/]+)\/book$/.exec(pathname);
    if (book) {
      const id = decodeURIComponent(book[1]);
      if (knownMarkets && !knownMarkets.includes(id)) return { status: 404, body: { error: "unknown_market" } };
      return { status: 200, body: marketBook(model, id, positiveBound(query.depth, 25, 100)) };
    }
    const account = /^\/accounts\/(0x[0-9a-fA-F]{40})$/.exec(pathname);
    if (account) {
      return { status: 200, body: accountView(model, account[1], positiveBound(query.limit, 50, 100), query.cursor) };
    }
    if (pathname === "/strategies") {
      const records = model.strategies?.records ?? [];
      const selected = query.marketId ? records.filter((r) => r.marketId === query.marketId) : records;
      return { status: 200, body: collect(selected, positiveBound(query.limit, 50, 100), query.cursor) };
    }
    return { status: 404, body: { error: "not_found" } };
  } catch (error) {
    return { status: error instanceof RangeError || error instanceof TypeError ? 400 : 500,
      body: { error: "invalid_request" } };
  }
}

/** Validate chain/head pairing before exposing a combined API snapshot. */
export function composeReadModel(
  snapshot: ApiSnapshot,
  strategies?: StrategySnapshot,
  diagnostics?: OperatorDiagnostics,
): ReadModel {
  if (snapshot.version !== 1 || !Number.isSafeInteger(snapshot.chainId) || snapshot.chainId <= 0) {
    throw new TypeError("invalid snapshot");
  }
  if (strategies && strategies.version !== 1) throw new TypeError("invalid strategy snapshot");
  if (diagnostics && snapshot.head && diagnostics.headBlock !== snapshot.head.number) {
    throw new Error("diagnostics and snapshot heads differ");
  }
  return { snapshot, ...(strategies ? { strategies } : {}), ...(diagnostics ? { diagnostics } : {}) };
}

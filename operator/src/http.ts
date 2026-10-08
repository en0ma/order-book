import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { URL } from "node:url";
import { routeRead, type ReadModel } from "./read-model.js";

export interface HttpRuntimeOptions {
  /** Application-provided, atomically captured canonical snapshot. Never read partially mutated state. */
  snapshot(): Promise<ReadModel> | ReadModel;
  markets: readonly string[];
  /** Required for private account views. Return true only for an authenticated caller. */
  authorizeAccount?: (request: IncomingMessage, address: string) => Promise<boolean> | boolean;
  maxPathBytes?: number;
  maxQueryBytes?: number;
  requestTimeoutMs?: number;
  /** Bound application-level concurrency, including hung upstream providers. */
  maxConcurrentRequests?: number;
  /** Optional request telemetry; never receives credentials or account addresses. */
  onRequest?: (result: { status: number; durationMs: number; route: string }) => void;
}
export interface HttpRuntime {
  server: Server;
  listen(port: number, host?: string): Promise<void>;
  close(): Promise<void>;
  metrics(): { active: number; total: number; rejected: number; errors: number };
}
function fail(response: ServerResponse, status: number, code: string): void {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
    "x-content-type-options": "nosniff" });
  response.end(JSON.stringify({ error: code }));
}
function json(response: ServerResponse, status: number, body: unknown, head?: string): void {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
    "x-content-type-options": "nosniff", ...(head ? { "x-canonical-head": head } : {}) });
  response.end(JSON.stringify(body));
}
function bound(value: number | undefined, fallback: number, max: number): number {
  const n = value ?? fallback;
  if (!Number.isSafeInteger(n) || n < 1 || n > max) throw new TypeError("invalid HTTP runtime limit");
  return n;
}
/**
 * Self-hosted, read-only bridge. Only binds when the caller explicitly invokes listen().
 * Operators own RPC, checkpoint, chain safety, TLS reverse proxy, and production authentication.
 */
export function createHttpRuntime(options: HttpRuntimeOptions): HttpRuntime {
  const maxPath = bound(options.maxPathBytes, 1024, 8192);
  const maxQuery = bound(options.maxQueryBytes, 2048, 8192);
  const timeout = bound(options.requestTimeoutMs, 10_000, 120_000);
  const capacity = bound(options.maxConcurrentRequests, 64, 4096);
  let active = 0;
  let total = 0;
  let rejected = 0;
  let errors = 0;
  let draining = false;
  if (typeof options.snapshot !== "function" || !Array.isArray(options.markets)) {
    throw new TypeError("snapshot provider and market IDs required");
  }
  const marketIds = [...options.markets];
  if (marketIds.some(id => typeof id !== "string" || !id || id.length > 128) ||
      new Set(marketIds).size !== marketIds.length) throw new TypeError("invalid market configuration");

  // Node's requestTimeout controls request-body receipt, not awaited application work.
  // Race provider promises against a deadline; late rejection remains handled by the race.
  function withDeadline<T>(work: Promise<T> | T): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("provider deadline exceeded")), timeout);
      Promise.resolve(work).then(
        value => { clearTimeout(timer); resolve(value); },
        error => { clearTimeout(timer); reject(error); },
      );
    });
  }
  const server = createServer(async (request, response) => {
    const started = Date.now();
    total++;
    if (draining || active >= capacity) {
      rejected++;
      fail(response, 503, draining ? "server_draining" : "capacity_exceeded");
      return;
    }
    active++;
    let completed = false;
    const complete = () => {
      if (completed) return;
      completed = true;
      active--;
      const pathname = (request.url ?? "").split("?")[0];
      const route = pathname.startsWith("/accounts/") ? "/accounts/:address"
        : pathname.startsWith("/markets/") && pathname.endsWith("/book")
          ? "/markets/:id/book" : pathname;
      try { options.onRequest?.({ status: response.statusCode, durationMs: Date.now() - started, route }); }
      catch { /* Telemetry cannot affect HTTP correctness. */ }
    };
    response.once("finish", complete);
    response.once("close", complete);
    try {
      if (request.method !== "GET" && request.method !== "HEAD") {
        fail(response, 405, "method_not_allowed"); return;
      }
      const raw = request.url ?? "";
      if (Buffer.byteLength(raw) > maxPath + maxQuery) {
        fail(response, 414, "request_uri_too_long"); return;
      }
      const boundary = raw.indexOf("?");
      const path = boundary < 0 ? raw : raw.slice(0, boundary);
      const query = boundary < 0 ? "" : raw.slice(boundary + 1);
      if (Buffer.byteLength(path) > maxPath || Buffer.byteLength(query) > maxQuery) {
        fail(response, 414, "request_uri_too_long"); return;
      }
      const url = new URL(raw, "http://localhost");
      if (url.searchParams.size > 20) {
        fail(response, 400, "too_many_query_params"); return;
      }
      const filter: Record<string, string> = {};
      for (const [key, value] of url.searchParams) {
        if (!["depth", "limit", "cursor", "marketId"].includes(key) || key in filter) {
          fail(response, 400, "invalid_query"); return;
        }
        filter[key] = value;
      }
      const account = /^\/accounts\/(0x[0-9a-fA-F]{40})$/.exec(url.pathname);
      if (account) {
        if (!options.authorizeAccount || !(await withDeadline(Promise.resolve().then(() => options.authorizeAccount!(request, account[1]))))) {
          fail(response, 403, "account_access_denied"); return;
        }
      }
      const model = await withDeadline(Promise.resolve().then(() => options.snapshot()));
      if (!model || !model.snapshot || !model.snapshot.head) {
        fail(response, 503, "canonical_snapshot_unavailable"); return;
      }
      const result = routeRead(model, "GET", url.pathname, filter, marketIds);
      const canonicalHead = model.snapshot.head.hash;
      if (request.method === "HEAD") {
        response.writeHead(result.status, { "cache-control": "no-store",
          "x-canonical-head": canonicalHead, "x-content-type-options": "nosniff" });
        response.end(); return;
      }
      json(response, result.status, result.body, canonicalHead);
    } catch {
      errors++;
      if (!response.headersSent) fail(response, 503, "snapshot_or_authorization_unavailable");
      else response.end();
    }
  });
  server.requestTimeout = timeout;
  server.headersTimeout = Math.min(timeout, 60_000);
  server.maxRequestsPerSocket = 100;
  return {
    server,
    listen(port, host = "127.0.0.1") {
      if (!Number.isSafeInteger(port) || port < 0 || port > 65535) {
        return Promise.reject(new RangeError("invalid listen port"));
      }
      return new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => {
          server.off("error", reject);
          resolve();
        });
      });
    },
    close() {
      draining = true;
      return new Promise<void>((resolve, reject) => {
        server.close(error => error ? reject(error) : resolve());
        server.closeIdleConnections();
      });
    },
    metrics() { return { active, total, rejected, errors }; },
  };
}

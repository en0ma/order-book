import type { JsonRpcTransport } from "./rpc-adapter.js";

export interface HttpJsonRpcOptions {
  timeoutMs?: number;
  maxAttempts?: number;
  retryDelayMs?: number;
  fetcher?: typeof fetch;
  headers?: Readonly<Record<string, string>>;
}

/** HTTP JSON-RPC transport: retry transient transport faults, never malformed RPC responses. */
export function createHttpJsonRpcTransport(endpoint: string, options: HttpJsonRpcOptions = {}): JsonRpcTransport {
  const url = new URL(endpoint);
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new TypeError("RPC endpoint must use HTTP(S)");
  const timeout = options.timeoutMs ?? 10_000;
  const attempts = options.maxAttempts ?? 3;
  const delay = options.retryDelayMs ?? 100;
  if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > 120_000 ||
      !Number.isSafeInteger(attempts) || attempts < 1 || attempts > 10 ||
      !Number.isSafeInteger(delay) || delay < 0 || delay > 30_000) {
    throw new RangeError("invalid RPC transport limits");
  }
  const send = options.fetcher ?? fetch;
  let counter = 0;
  return {
    async request(method, params) {
      if (typeof method !== "string" || !/^[_a-zA-Z][_a-zA-Z0-9]*$/.test(method) || !Array.isArray(params)) {
        throw new TypeError("invalid RPC request");
      }
      for (let attempt = 1; attempt <= attempts; attempt++) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeout);
        let retry = false;
        let fetching = false;
        try {
          const id = ++counter;
          fetching = true;
          const response = await send(url.toString(), {
            method: "POST", signal: controller.signal,
            headers: { "content-type": "application/json", ...options.headers },
            body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
          });
          fetching = false;
          if (!response.ok) {
            retry = [408, 429, 500, 502, 503, 504].includes(response.status);
            if (!retry) throw new Error("RPC HTTP status " + response.status);
            throw new Error("RPC temporarily unavailable (HTTP " + response.status + ")");
          }
          const data: unknown = await response.json();
          if (!data || typeof data !== "object" || Array.isArray(data)) throw new Error("invalid RPC response");
          const envelope = data as Record<string, unknown>;
          if (envelope.jsonrpc !== "2.0" || envelope.id !== id ||
              !("result" in envelope) || "error" in envelope) {
            throw new Error("invalid or error RPC response");
          }
          return envelope.result;
        } catch (error) {
          if (controller.signal.aborted || (fetching && error instanceof TypeError)) retry = true;
          if (attempt >= attempts || !retry) throw error;
        } finally {
          clearTimeout(timer);
        }
        if (delay) await new Promise(resolve => setTimeout(resolve, Math.min(30_000, delay * 2 ** (attempt - 1))));
      }
      throw new Error("RPC request exhausted retries");
    },
  };
}

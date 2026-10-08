import type { JsonRpcTransport } from "./rpc-adapter.js";
export interface HttpJsonRpcOptions {
  timeoutMs?: number;
  maxAttempts?: number;
  retryDelayMs?: number;
  fetcher?: typeof fetch;
  headers?: Readonly<Record<string, string>>;
}
export declare function createHttpJsonRpcTransport(
  endpoint: string, options?: HttpJsonRpcOptions,
): JsonRpcTransport;

import type { IncomingMessage, Server } from "node:http";
import type { ReadModel } from "./read-model.js";
export interface HttpRuntimeOptions {
  snapshot(): Promise<ReadModel> | ReadModel;
  markets: readonly string[];
  authorizeAccount?: (request: IncomingMessage, address: string) => Promise<boolean> | boolean;
  maxPathBytes?: number;
  maxQueryBytes?: number;
  requestTimeoutMs?: number;
}
export interface HttpRuntime {
  server: Server;
  listen(port: number, host?: string): Promise<void>;
  close(): Promise<void>;
}
export declare function createHttpRuntime(options: HttpRuntimeOptions): HttpRuntime;

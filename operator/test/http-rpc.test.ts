import test from "node:test";
import assert from "node:assert/strict";
import { createHttpJsonRpcTransport } from "../dist/http-rpc.js";
import { createCanonicalRpcAdapter } from "../dist/rpc-adapter.js";
const addr = "0x" + "1".repeat(40);
const H0 = "0x" + "0".repeat(64), H1 = "0x" + "1".repeat(64);
const manifest = { schemaVersion: 1, chainId: 1, deploymentBlock: 1,
  collateral: { token: addr, decimals: 18 },
  markets: [{ id: "ETH", core: addr, advanced: addr, oracle: addr }] };
test("HTTP JSON-RPC transport retries temporary errors and checks response identity", async () => {
  let calls = 0;
  const transport = createHttpJsonRpcTransport("https://rpc.invalid", {
    maxAttempts: 3, retryDelayMs: 0, fetcher: async (_url, options) => {
      calls++;
      const request = JSON.parse(options.body);
      if (calls === 1) return { ok: false, status: 503 };
      return { ok: true, json: async () => ({ jsonrpc: "2.0", id: request.id, result: "0x1" }) };
    },
  });
  assert.equal(await transport.request("eth_chainId", []), "0x1");
  assert.equal(calls, 2);
  const invalid = createHttpJsonRpcTransport("https://rpc.invalid", {
    maxAttempts: 3, retryDelayMs: 0,
    fetcher: async () => ({ ok: true, json: async () => ({ jsonrpc: "2.0", id: 999, result: "0x1" }) }),
  });
  await assert.rejects(invalid.request("eth_chainId", []), /invalid or error RPC response/);
});
test("transport does not retry JSON-RPC application errors or permanent HTTP failures", async () => {
  let calls = 0;
  const transport = createHttpJsonRpcTransport("https://rpc.invalid", {
    maxAttempts: 3, retryDelayMs: 0,
    fetcher: async () => { calls++; return { ok: false, status: 401 }; },
  });
  await assert.rejects(transport.request("eth_chainId", []), /401/);
  assert.equal(calls, 1);
  assert.throws(() => createHttpJsonRpcTransport("file:///tmp/rpc"), /HTTP/);
});
test("canonical adapter rejects untrusted addresses and duplicate log indexes", async () => {
  let mode = "untrusted";
  const transport = { request: async method => {
    if (method === "eth_chainId") return "0x1";
    if (method === "eth_getBlockByNumber") return { number: "0x1", hash: H1, parentHash: H0 };
    if (method === "eth_getLogs") {
      const entry = { address: mode === "untrusted" ? "0x" + "2".repeat(40) : addr,
        blockHash: H1, blockNumber: "0x1", transactionIndex: "0x0", logIndex: "0x0",
        topics: [], data: "0x" };
      return mode === "duplicate" ? [entry, entry] : [entry];
    }
    throw new Error(method);
  } };
  const adapter = createCanonicalRpcAdapter(transport, { decode: () => undefined });
  const block = await adapter.getBlock(1);
  await assert.rejects(adapter.getEvents(block, manifest), /unconfigured address/);
  mode = "duplicate";
  await assert.rejects(adapter.getEvents(block, manifest), /duplicate RPC log position/);
});

test("transient fetch network failures retry, but malformed successful responses do not", async () => {
  let networkCalls = 0;
  const transport = createHttpJsonRpcTransport("https://rpc.invalid", {
    maxAttempts: 3, retryDelayMs: 0,
    fetcher: async (_url, options) => {
      networkCalls++;
      if (networkCalls < 3) throw new TypeError("fetch failed");
      const request = JSON.parse(options.body);
      return { ok: true, json: async () => ({ jsonrpc: "2.0", id: request.id, result: "0x1" }) };
    },
  });
  assert.equal(await transport.request("eth_chainId", []), "0x1");
  assert.equal(networkCalls, 3);

  let malformedCalls = 0;
  const malformed = createHttpJsonRpcTransport("https://rpc.invalid", {
    maxAttempts: 3, retryDelayMs: 0,
    fetcher: async () => {
      malformedCalls++;
      return { ok: true, json: async () => { throw new SyntaxError("invalid JSON"); } };
    },
  });
  await assert.rejects(malformed.request("eth_chainId", []), /invalid JSON/);
  assert.equal(malformedCalls, 1);
});

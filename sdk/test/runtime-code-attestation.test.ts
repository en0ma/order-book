import test from "node:test";
import assert from "node:assert/strict";
import {
  attestRuntimeCodeOrThrow, RuntimeCodeAttestationError,
} from "../dist/index.js";

const A = "0x1111111111111111111111111111111111111111";
const B = "0x2222222222222222222222222222222222222222";
const expected = [
  { address: A, runtimeCode: "0x60016002", label: "Core" },
  { address: B, runtimeCode: "0x60036004", label: "Advanced" },
];
function adapter(code = { [A]: "0x60016002", [B]: "0x60036004" }, id = 1) {
  return {
    chainId: async () => id,
    getCode: async addr => code[addr],
  };
}
test("attests all reviewed runtime code exactly, case-insensitively", async () => {
  await attestRuntimeCodeOrThrow(1, expected, adapter());
  await attestRuntimeCodeOrThrow(1, [
    { address: A, runtimeCode: "0X60016002".replace("0X", "0x") },
  ], adapter({ [A]: "0x60016002" }));
});
test("detects code that has the same ABI but different runtime bytes", async () => {
  await assert.rejects(
    attestRuntimeCodeOrThrow(1, expected, adapter({ [A]: "0x60016003", [B]: "0x60036004" })),
    error => error instanceof RuntimeCodeAttestationError &&
      error.failures.length === 1 && error.failures[0].label === "Core",
  );
});
test("rejects missing, malformed or unreadable deployed code", async () => {
  for (const code of ["0x", "0x0", undefined]) {
    await assert.rejects(attestRuntimeCodeOrThrow(
      1, expected, adapter({ [A]: code, [B]: "0x60036004" })
    ), RuntimeCodeAttestationError);
  }
  await assert.rejects(attestRuntimeCodeOrThrow(1, expected, {
    chainId: async () => 1,
    getCode: async () => { throw new Error("rpc offline"); },
  }), RuntimeCodeAttestationError);
});
test("chain mismatch halts before any code is requested", async () => {
  let calls = 0;
  await assert.rejects(attestRuntimeCodeOrThrow(1, expected, {
    chainId: async () => 5,
    getCode: async () => { calls++; return "0x60016002"; },
  }), RuntimeCodeAttestationError);
  assert.equal(calls, 0);
});
test("rejects empty expected set, duplicate addresses and malformed artifacts", async () => {
  await assert.rejects(attestRuntimeCodeOrThrow(1, [], adapter()), /nonempty/);
  await assert.rejects(attestRuntimeCodeOrThrow(1, [expected[0], expected[0]], adapter()), /duplicate/);
  await assert.rejects(attestRuntimeCodeOrThrow(1, [{ address: A, runtimeCode: "0x" }], adapter()), /invalid/);
});

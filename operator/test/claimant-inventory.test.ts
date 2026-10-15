import test from "node:test";
import assert from "node:assert/strict";
import { replayClaimantInventory } from "../dist/claimant-inventory.js";
const hash = digit => "0x" + digit.repeat(64);
const address = digit => "0x" + digit.repeat(40);
const block = (number, digit, parentDigit) => ({
  number, hash: hash(digit), parentHash: hash(parentDigit),
});
const event = (blockRef, name, args, index = 0) => ({
  chainId: 1, blockNumber: blockRef.number, blockHash: blockRef.hash,
  transactionIndex: 0, logIndex: index, address: address("9"), name, args,
});
const a = block(10, "a", "0"), b = block(11, "b", "a");
const history = [
  { block: a, events: [event(a, "Deposited", { account: address("2") })] },
  { block: b, events: [
    event(b, "Trade", { taker: address("1") }),
    event(b, "LiquidityAdded", { maker: address("2") }, 1),
  ] },
];
test("canonical replay discovers unique sorted active/historical claimants", () => {
  assert.deepEqual(replayClaimantInventory(1, 10, history), {
    chainId: 1, deploymentBlock: 10, blockNumber: 11, blockHash: b.hash,
    accounts: [address("1"), address("2")], eventCount: 3,
  });
});
test("fail closed on missing deployment block, gaps, forks and reordered events", () => {
  assert.throws(() => replayClaimantInventory(1, 9, history), /noncanonical/);
  assert.throws(() => replayClaimantInventory(1, 10, [history[1]]), /noncanonical/);
  assert.throws(() => replayClaimantInventory(1, 10, [
    history[0], { ...history[1], block: { ...b, parentHash: hash("c") } },
  ]), /noncanonical/);
  assert.throws(() => replayClaimantInventory(1, 10, [
    history[0], { ...history[1], events: [...history[1].events].reverse() },
  ]), /out-of-order/);
});
test("rejects undocumented events, absent accounts, mismatched hashes and duplicates", () => {
  const mutate = events => [history[0], { ...history[1], events }];
  assert.throws(() => replayClaimantInventory(1, 10, mutate([
    event(b, "UnknownMarketEvent", { account: address("3") }),
  ])), /unclassified/);
  assert.throws(() => replayClaimantInventory(1, 10, mutate([
    event(b, "Trade", { maker: address("3") }),
  ])), /claimant address/);
  assert.throws(() => replayClaimantInventory(1, 10, mutate([
    { ...event(b, "Trade", { taker: address("3") }), blockHash: hash("e") },
  ])), /invalid/);
  assert.throws(() => replayClaimantInventory(1, 10, mutate([
    event(b, "Trade", { taker: address("3") }),
    event(b, "Trade", { taker: address("3") }),
  ])), /duplicate/);
});

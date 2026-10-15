import test from "node:test";
import assert from "node:assert/strict";
import { replayClaimantInventory, discoverClaimantsAtAnchor } from "../dist/claimant-inventory.js";
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

test("anchor-pinned replay succeeds with authenticated contiguous history", async () => {
  const byNumber = new Map(history.map(x => [x.block.number, x]));
  const reader = {
    getChainId: async () => 1,
    getBlock: async n => byNumber.get(n).block,
    getEvents: async b => byNumber.get(b.number).events,
  };
  const inventory = await discoverClaimantsAtAnchor(reader, 10, {
    chainId: 1, blockNumber: 11, blockHash: b.hash,
  });
  assert.deepEqual(inventory.accounts, [address("1"), address("2")]);
  await assert.rejects(discoverClaimantsAtAnchor(reader, 10, {
    chainId: 1, blockNumber: 11, blockHash: hash("f"),
  }), /trusted finalized anchor/);
});
test("anchor-pinned replay rejects wrong chain and changing canonical endpoints", async () => {
  let calls = 0;
  const reader = {
    getChainId: async () => 1,
    getBlock: async n => {
      calls++;
      return calls > 2 && n === 10 ? { ...a, hash: hash("d") } : n === 10 ? a : b;
    },
    getEvents: async blockRef => blockRef.number === 10 ? history[0].events : history[1].events,
  };
  await assert.rejects(discoverClaimantsAtAnchor(reader, 10, {
    chainId: 2, blockNumber: 11, blockHash: b.hash,
  }), /chain mismatch/);
  await assert.rejects(discoverClaimantsAtAnchor(reader, 10, {
    chainId: 1, blockNumber: 11, blockHash: b.hash,
  }), /changed during history replay/);
});

test("explicit non-claimant protocol events do not block discovery", () => {
  const extra = event(b, "ProtocolFeesAllocatedToInsurance", { amount: 7n }, 2);
  const result = replayClaimantInventory(1, 10, [
    history[0], { ...history[1], events: [...history[1].events, extra] },
  ]);
  assert.deepEqual(result.accounts, [address("1"), address("2")]);
  assert.equal(result.eventCount, 4);
});

test("collateral-lock events identify claimants even without deposits or trades", () => {
  const onlyLock = [{ block: a, events: [
    event(a, "LockedCollateralUpdated", { account: address("4"),
      previousLocked: 0n, nextLocked: 1n }),
  ] }];
  assert.deepEqual(replayClaimantInventory(1, 10, onlyLock).accounts, [address("4")]);
  assert.throws(() => replayClaimantInventory(1, 10, [{
    block: a, events: [event(a, "LockedCollateralUpdated", { previousLocked: 0n })],
  }]), /missing or invalid claimant address/);
});

test("deployment-scoped claimant replay rejects untrusted event emitters", async () => {
  const { replayClaimantInventoryForDeployment } = await import("../dist/claimant-inventory.js");
  assert.deepEqual(replayClaimantInventoryForDeployment(1, 10, history, [address("9")]).accounts,
    [address("1"), address("2")]);
  assert.throws(() => replayClaimantInventoryForDeployment(1, 10, history, [address("8")]),
    /outside trusted deployment/);
  assert.throws(() => replayClaimantInventoryForDeployment(1, 10, history, [address("9"), address("9")]),
    /duplicate deployment contract/);
  assert.throws(() => replayClaimantInventoryForDeployment(1, 10, history, []),
    /independent deployment contract inventory/);
});

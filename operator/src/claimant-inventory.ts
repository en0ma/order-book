import type { BlockRef, NormalizedEvent } from "./index.js";

/**
 * Deterministic account discovery from an externally authenticated, complete
 * history. This is NOT completeness proof: the caller must attest that all
 * relevant deployment contracts, ABI topics and logs were covered.
 * No result from this module permits a token transfer.
 */
export interface ClaimantHistoryBlock {
  block: BlockRef;
  events: readonly NormalizedEvent[];
}
export interface ClaimantInventory {
  chainId: number;
  deploymentBlock: number;
  blockNumber: number;
  blockHash: string;
  accounts: readonly string[];
  eventCount: number;
}

const address = /^0x[0-9a-fA-F]{40}$/;
const hash = /^0x[0-9a-fA-F]{64}$/;
/** Only known account-bearing economic events; new ABIs require an explicit audit. */
const claimantField: Readonly<Record<string, string>> = {
  CollateralCredited: "account",
  CollateralDebited: "account",
  LiquidityAdded: "maker",
  LiquidityRemoved: "maker",
  MakerSettled: "maker",
  Trade: "taker",
  FundingSettled: "account",
  BadDebtCovered: "account",
  Deposited: "account",
  Withdrawn: "account",
  PortfolioWithdrawn: "account",
  PortfolioLockSynchronized: "account",
};

export function replayClaimantInventory(
  chainId: number,
  deploymentBlock: number,
  history: readonly ClaimantHistoryBlock[],
): ClaimantInventory {
  if (!Number.isSafeInteger(chainId) || chainId <= 0 ||
      !Number.isSafeInteger(deploymentBlock) || deploymentBlock < 0 ||
      !Array.isArray(history) || history.length === 0) {
    throw new Error("complete nonempty deployment history required");
  }
  let previousHash = "";
  const accounts = new Set<string>();
  let eventCount = 0;
  for (let i = 0; i < history.length; i++) {
    const { block, events } = history[i] ?? {};
    if (!block || block.number !== deploymentBlock + i ||
        typeof block.hash !== "string" || !hash.test(block.hash) ||
        typeof block.parentHash !== "string" || !hash.test(block.parentHash) ||
        (i > 0 && block.parentHash.toLowerCase() !== previousHash) ||
        !Array.isArray(events)) {
      throw new Error("noncanonical or incomplete claimant block sequence");
    }
    let lastTx = -1;
    let lastLog = -1;
    for (const event of events) {
      if (!event || event.chainId !== chainId ||
          event.blockNumber !== block.number ||
          typeof event.blockHash !== "string" ||
          event.blockHash.toLowerCase() !== block.hash.toLowerCase() ||
          !Number.isSafeInteger(event.transactionIndex) ||
          !Number.isSafeInteger(event.logIndex) ||
          event.transactionIndex < 0 || event.logIndex < 0 ||
          (event.transactionIndex < lastTx) ||
          (event.transactionIndex === lastTx && event.logIndex <= lastLog)) {
        throw new Error("invalid, duplicate or out-of-order canonical event");
      }
      lastTx = event.transactionIndex;
      lastLog = event.logIndex;
      const field = claimantField[event.name];
      if (!field) throw new Error("unclassified event requires ABI coverage audit: " + event.name);
      const account = event.args?.[field];
      if (typeof account !== "string" || !address.test(account)) {
        throw new Error("missing or invalid claimant address in " + event.name);
      }
      accounts.add(account.toLowerCase());
      eventCount++;
    }
    previousHash = block.hash.toLowerCase();
  }
  const terminal = history[history.length - 1].block;
  return {
    chainId, deploymentBlock, blockNumber: terminal.number,
    blockHash: previousHash, accounts: [...accounts].sort(), eventCount,
  };
}

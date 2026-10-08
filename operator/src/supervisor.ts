import type { RecoveryPublication } from "./publication.js";
import type { RecoveryCycleResult } from "./recovery-cycle.js";
import type { KeeperTask, IdempotentKeeperExecutor } from "./index.js";
import type { CanonicalHeadVerifier, KeeperAdmissionResult } from "./recovery.js";

export interface SupervisorOptions {
  intervalMs?: number;
  maxBackoffMs?: number;
  signal?: AbortSignal;
  onCycle?: (event: { kind: "ready" | "lagging" | "error"; attempt: number; head?: number; message?: string }) => void;
}
export interface OperatorSupervisor {
  /** Resolves only after stop/abort. Do not start a second loop on the same controller. */
  run(): Promise<void>;
  /** Ask the active loop to stop after its current recovery pass. */
  stop(): void;
  /** Keeper submissions are rejected unless this supervisor has confirmed readiness. */
  submit(tasks: readonly KeeperTask[], executor: IdempotentKeeperExecutor,
    verifier: CanonicalHeadVerifier): Promise<KeeperAdmissionResult>;
  status(): { running: boolean; ready: boolean; failures: number; cycles: number };
}

/** Supervise an existing publication controller without holding wallet keys or RPC connections. */
export function createOperatorSupervisor(
  publication: RecoveryPublication, options: SupervisorOptions = {},
): OperatorSupervisor {
  const interval = options.intervalMs ?? 1_000;
  const maxBackoff = options.maxBackoffMs ?? 30_000;
  if (!Number.isSafeInteger(interval) || interval < 1 || interval > 3_600_000 ||
      !Number.isSafeInteger(maxBackoff) || maxBackoff < interval || maxBackoff > 3_600_000) {
    throw new RangeError("invalid supervisor interval or retry limit");
  }
  let running = false;
  let stopped = false;
  let ready = false;
  let failures = 0;
  let cycles = 0;
  let wake: (() => void) | undefined;
  function wait(ms: number): Promise<void> {
    if (stopped || options.signal?.aborted) return Promise.resolve();
    return new Promise(resolve => {
      const timer = setTimeout(() => { wake = undefined; resolve(); }, ms);
      const finish = () => { clearTimeout(timer); wake = undefined; resolve(); };
      wake = finish;
      options.signal?.addEventListener("abort", finish, { once: true });
    });
  }
  function emit(event: { kind: "ready" | "lagging" | "error"; attempt: number; head?: number; message?: string }) {
    try { options.onCycle?.(event); } catch { /* observer failures must not change safety */ }
  }
  return {
    status: () => ({ running, ready: running && ready && publication.ready(), failures, cycles }),
    stop() { stopped = true; ready = false; wake?.(); },
    async run() {
      if (running) throw new Error("supervisor already running");
      if (stopped || options.signal?.aborted) return;
      running = true;
      ready = false;
      try {
        while (!stopped && !options.signal?.aborted) {
          cycles++;
          try {
            const result: RecoveryCycleResult = await publication.refresh();
            ready = result.readiness.ready && publication.ready();
            failures = 0;
            emit({ kind: ready ? "ready" : "lagging", attempt: cycles, head: result.head.number });
          } catch (error) {
            ready = false;
            failures++;
            emit({ kind: "error", attempt: cycles,
              message: error instanceof Error ? error.message : "unknown recovery error" });
          }
          if (stopped || options.signal?.aborted) break;
          const delay = failures === 0 ? interval : Math.min(maxBackoff, interval * 2 ** Math.min(16, failures - 1));
          await wait(delay);
        }
      } finally {
        ready = false;
        running = false;
      }
    },
    async submit(tasks, executor, verifier) {
      if (!running || !ready || !publication.ready() || stopped || options.signal?.aborted) {
        throw new Error("keeper submission rejected: supervisor is not ready");
      }
      return publication.submit(tasks, executor, verifier);
    },
  };
}

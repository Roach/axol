// Approval-flow helpers: pending-request storage, decision writes, and
// the small polling loop that backs the optional `hold` inline response.
//
// State shape (all stored on the same KVStore as the webhook queue):
//
//   perm:pending:<request_id>  → JSON { request_id, envelope, expiresAt, createdAt }
//   perm:decision:<request_id> → JSON { behavior, decidedAt }   (behavior may also be "expired")
//
// There's deliberately no perm:index:* key. Pending items piggy-back on
// the main queue (same `kind: "permission"` envelopes flowing through
// enqueue/pullSince), so the forwarder already discovers them; the two
// perm:* keys are the *decision record* side of the flow, not another
// queue.
//
// Runtime notes:
//   - `hold`-inline uses a short in-handler poll (KV read-loop). Eventual
//     consistency on CF KV (~60 s) means `hold` is best-effort: if the
//     decision write reaches a different edge than the holding handler,
//     we'll time out and return 202. Callers must handle that anyway.
//   - Expiry is enforced lazily on read; a scheduled sweep is nice to
//     have but not required for correctness.

import type { KVStore } from './storage';

export const PENDING_PREFIX  = 'perm:pending:';
export const DECISION_PREFIX = 'perm:decision:';

export const DEFAULT_EXPIRES_MS = 10 * 60_000;   // 10 min
export const MIN_EXPIRES_MS     = 30_000;        //  30 s
export const MAX_EXPIRES_MS     = 24 * 3_600_000;// 24 h

export const MAX_HOLD_SECONDS = 25;  // headroom under CF's 30 s idle cap
export const HOLD_POLL_START_MS = 400;
export const HOLD_POLL_MAX_MS   = 1_500;

export type Decision = 'allow' | 'deny' | 'expired';

export interface PendingRecord {
  request_id: string;
  envelope: Record<string, unknown>;
  createdAt: number;
  expiresAt: number;
}

export interface DecisionRecord {
  behavior: Decision;
  decidedAt: number;
}

/// Clamp a caller-provided expires_at (either an ISO string, a number of
/// seconds, or undefined) to the safe range. Returns an absolute ms
/// timestamp. Throws on values that are explicitly too short or malformed
/// so the caller can 400 — silently clamping short windows masks bugs.
export function resolveExpiresAt(input: unknown, now: number): number {
  if (input == null) return now + DEFAULT_EXPIRES_MS;
  let ms: number;
  if (typeof input === 'number') {
    // Treat bare numbers as "seconds from now" — the most common shorthand.
    ms = now + input * 1000;
  } else if (typeof input === 'string') {
    const parsed = Date.parse(input);
    if (!Number.isFinite(parsed)) {
      throw new Error('expires_at: unparseable timestamp');
    }
    ms = parsed;
  } else {
    throw new Error('expires_at: must be ISO string or seconds (number)');
  }
  const delta = ms - now;
  if (delta < MIN_EXPIRES_MS) {
    throw new Error(`expires_at: must be at least ${MIN_EXPIRES_MS / 1000}s in the future`);
  }
  if (delta > MAX_EXPIRES_MS) {
    throw new Error(`expires_at: must be at most ${MAX_EXPIRES_MS / 3_600_000}h in the future`);
  }
  return ms;
}

/// Write a pending permission record. Idempotent-ish: re-writing the same
/// request_id replaces the pending record — callers using retries should
/// use the same `request_id` so they don't double-queue.
export async function putPending(store: KVStore, rec: PendingRecord): Promise<void> {
  await store.put(PENDING_PREFIX + rec.request_id, JSON.stringify(rec));
}

export async function getPending(
  store: KVStore,
  requestId: string,
): Promise<PendingRecord | null> {
  const raw = await store.get(PENDING_PREFIX + requestId);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as PendingRecord;
  } catch {
    return null;
  }
}

export async function deletePending(store: KVStore, requestId: string): Promise<void> {
  await store.delete(PENDING_PREFIX + requestId);
}

/// Write a decision. First write wins — on a re-write, the stored value
/// is preserved and the existing record is returned.
export async function putDecision(
  store: KVStore,
  requestId: string,
  decision: Decision,
  now: number,
): Promise<DecisionRecord> {
  const existing = await getDecision(store, requestId);
  if (existing) return existing;
  const rec: DecisionRecord = { behavior: decision, decidedAt: now };
  await store.put(DECISION_PREFIX + requestId, JSON.stringify(rec));
  // Pending is no longer needed — the decision record is the durable
  // record of the answer. Leaving pending around just wastes KV.
  await deletePending(store, requestId);
  return rec;
}

export async function getDecision(
  store: KVStore,
  requestId: string,
): Promise<DecisionRecord | null> {
  const raw = await store.get(DECISION_PREFIX + requestId);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as DecisionRecord;
  } catch {
    return null;
  }
}

/// Lazy expiry check: if the pending has passed `expiresAt`, materialize
/// an "expired" decision in KV and return it; otherwise return null. This
/// is how callers discover expiry without a cron sweep — every read-path
/// gets the check for free.
export async function expireIfDue(
  store: KVStore,
  requestId: string,
  now: number,
): Promise<DecisionRecord | null> {
  const pending = await getPending(store, requestId);
  if (!pending) return null;
  if (now < pending.expiresAt) return null;
  return putDecision(store, requestId, 'expired', now);
}

/// Resolve the current status for an id:
///   - if a decision is stored: return it.
///   - else if a pending exists and has expired: write "expired" and return.
///   - else if a pending exists and is still live: return null (pending).
///   - else: return "unknown" (never-heard-of this id).
export type Status =
  | { kind: 'decided'; decision: DecisionRecord }
  | { kind: 'pending'; pending: PendingRecord }
  | { kind: 'unknown' };

export async function statusOf(
  store: KVStore,
  requestId: string,
  now: number,
): Promise<Status> {
  const decided = await getDecision(store, requestId);
  if (decided) return { kind: 'decided', decision: decided };
  const pending = await getPending(store, requestId);
  if (!pending) return { kind: 'unknown' };
  if (now >= pending.expiresAt) {
    const rec = await putDecision(store, requestId, 'expired', now);
    return { kind: 'decided', decision: rec };
  }
  return { kind: 'pending', pending };
}

/// Hold-inline loop: poll the decision key up to `holdSeconds` with
/// exponential-ish backoff. Returns the decision if it lands in time,
/// null otherwise.
///
/// The poll interval starts at HOLD_POLL_START_MS and doubles up to
/// HOLD_POLL_MAX_MS. Over a 25 s hold that's ~20 KV gets — well under
/// Cloudflare's 50-subrequest free-tier limit and cheap to run.
export async function waitForDecision(
  store: KVStore,
  requestId: string,
  holdSeconds: number,
  now: () => number = Date.now,
): Promise<DecisionRecord | null> {
  const budgetMs = Math.max(0, Math.min(MAX_HOLD_SECONDS, holdSeconds)) * 1000;
  if (budgetMs === 0) return null;
  const start = now();
  let interval = HOLD_POLL_START_MS;
  while (true) {
    const dec = await getDecision(store, requestId);
    if (dec) return dec;
    const expired = await expireIfDue(store, requestId, now());
    if (expired) return expired;
    const elapsed = now() - start;
    const remaining = budgetMs - elapsed;
    if (remaining <= 0) return null;
    const sleep = Math.min(interval, remaining);
    await new Promise((r) => setTimeout(r, sleep));
    interval = Math.min(HOLD_POLL_MAX_MS, Math.round(interval * 1.5));
  }
}

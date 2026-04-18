// Short-TTL queue of inbound webhook bodies, backed by any KV-shaped
// store. Every enqueued item gets a monotonic ID (`<epoch_ms>-<uuid>`) so
// the forwarder's `since` cursor is a simple string compare. The item
// index is a JSON array under key `index`, bounded to the most recent N
// ids — older items are evicted from the index on enqueue if they're
// still around, but their stored bodies stay until explicitly acked or
// the backing store's expiration kicks in.
//
// Storage is selected by `getQueueStore(env)` in `./storage/index.ts`.
// This module knows nothing about runtimes; it just operates on a
// `KVStore` that satisfies the get/put/delete contract.

import type { KVStore } from './storage';
export type { KVStore } from './storage';

export interface QueueItem {
  id: string;
  source: string;
  receivedAt: number;
  body: unknown;
}

const INDEX_KEY = 'index';
const ITEM_PREFIX = 'item:';
const INDEX_CAP = 100;
const PULL_CAP = 25;

async function readIndex(store: KVStore): Promise<string[]> {
  const raw = await store.get(INDEX_KEY);
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((v): v is string => typeof v === 'string') : [];
  } catch {
    return [];
  }
}

async function writeIndex(store: KVStore, ids: string[]): Promise<void> {
  await store.put(INDEX_KEY, JSON.stringify(ids));
}

export async function enqueue(
  store: KVStore,
  input: { source: string; body: unknown },
): Promise<QueueItem> {
  const receivedAt = Date.now();
  const id = `${receivedAt.toString().padStart(14, '0')}-${crypto.randomUUID()}`;
  const item: QueueItem = { id, source: input.source, receivedAt, body: input.body };

  await store.put(ITEM_PREFIX + id, JSON.stringify(item));

  const index = await readIndex(store);
  index.push(id);
  // Keep the index bounded; newest ids stay at the tail.
  const trimmed = index.length > INDEX_CAP ? index.slice(index.length - INDEX_CAP) : index;
  await writeIndex(store, trimmed);

  return item;
}

export async function pullSince(
  store: KVStore,
  cursor: string | null,
): Promise<{ items: QueueItem[]; nextCursor: string }> {
  const index = await readIndex(store);
  const fresh = cursor ? index.filter((id) => id > cursor) : index;
  const page = fresh.slice(0, PULL_CAP);

  const items: QueueItem[] = [];
  for (const id of page) {
    const raw = await store.get(ITEM_PREFIX + id);
    if (!raw) continue; // evicted or never written
    try {
      items.push(JSON.parse(raw) as QueueItem);
    } catch {
      // Corrupt entry; skip silently, matching Axol's drop-on-bad-input posture.
    }
  }

  // Advance cursor even when the page was short: next pull resumes from the
  // last id we looked at, so a gap in stored bodies doesn't stall us.
  const nextCursor = page.length > 0 ? page[page.length - 1]! : (cursor ?? '');
  return { items, nextCursor };
}

export async function ackIds(
  store: KVStore,
  ids: string[],
): Promise<void> {
  if (ids.length === 0) return;
  const ackSet = new Set(ids);
  await Promise.all(ids.map((id) => store.delete(ITEM_PREFIX + id)));
  const index = await readIndex(store);
  const remaining = index.filter((id) => !ackSet.has(id));
  if (remaining.length !== index.length) {
    await writeIndex(store, remaining);
  }
}

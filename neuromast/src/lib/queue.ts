// KV-backed queue of inbound webhook bodies. Every enqueued item gets a
// monotonic ID (`<epoch_ms>-<uuid>`) so the poller's `since` cursor is a
// simple string compare. The item index is a JSON array under key `index`,
// bounded to the most recent N ids — older items are evicted from the
// index on enqueue if they're still around, but their stored bodies stay
// until explicitly acked or KV's natural expiration kicks in.

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

async function readIndex(env: { QUEUE: KVNamespace }): Promise<string[]> {
  const raw = await env.QUEUE.get(INDEX_KEY);
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((v): v is string => typeof v === 'string') : [];
  } catch {
    return [];
  }
}

async function writeIndex(env: { QUEUE: KVNamespace }, ids: string[]): Promise<void> {
  await env.QUEUE.put(INDEX_KEY, JSON.stringify(ids));
}

export async function enqueue(
  env: { QUEUE: KVNamespace },
  input: { source: string; body: unknown },
): Promise<QueueItem> {
  const receivedAt = Date.now();
  const id = `${receivedAt.toString().padStart(14, '0')}-${crypto.randomUUID()}`;
  const item: QueueItem = { id, source: input.source, receivedAt, body: input.body };

  await env.QUEUE.put(ITEM_PREFIX + id, JSON.stringify(item));

  const index = await readIndex(env);
  index.push(id);
  // Keep the index bounded; newest ids stay at the tail.
  const trimmed = index.length > INDEX_CAP ? index.slice(index.length - INDEX_CAP) : index;
  await writeIndex(env, trimmed);

  return item;
}

export async function pullSince(
  env: { QUEUE: KVNamespace },
  cursor: string | null,
): Promise<{ items: QueueItem[]; nextCursor: string }> {
  const index = await readIndex(env);
  const fresh = cursor ? index.filter((id) => id > cursor) : index;
  const page = fresh.slice(0, PULL_CAP);

  const items: QueueItem[] = [];
  for (const id of page) {
    const raw = await env.QUEUE.get(ITEM_PREFIX + id);
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
  env: { QUEUE: KVNamespace },
  ids: string[],
): Promise<void> {
  if (ids.length === 0) return;
  const ackSet = new Set(ids);
  await Promise.all(ids.map((id) => env.QUEUE.delete(ITEM_PREFIX + id)));
  const index = await readIndex(env);
  const remaining = index.filter((id) => !ackSet.has(id));
  if (remaining.length !== index.length) {
    await writeIndex(env, remaining);
  }
}

// Redis-backed KVStore for the Node-runtime deploy path (Railway, Fly,
// Render, any VM). Uses `ioredis`, which gives us connection pooling,
// reconnection, and sensible defaults without ceremony.
//
// This module must NEVER be imported at the top of `storage/index.ts` —
// `ioredis` pulls in Node built-ins (`net`, `tls`, `events`, `stream`)
// that Cloudflare Workers doesn't provide. It's dynamic-imported from
// the factory only when `STORAGE_KIND=redis` is selected, so the
// Workers bundle never sees it.

import Redis from 'ioredis';
import type { KVStore } from './index';

// Singleton connection per-URL. Reused across requests within the same
// Node process. For Railway's Docker container this is a long-lived
// connection; Redis itself handles idle timeouts / reconnects.
let cached: { url: string; store: KVStore } | null = null;

export function createRedisKVStore(url: string): KVStore {
  if (cached && cached.url === url) return cached.store;

  const client = new Redis(url, {
    // Don't crash the whole process on a transient Redis blip —
    // ioredis reconnects automatically.
    maxRetriesPerRequest: 3,
    // Fail pulled requests fast rather than hanging a webhook for
    // minutes during an outage. 5s is plenty for Railway's in-VPC Redis.
    connectTimeout: 5_000,
  });

  client.on('error', (err) => {
    console.error('neuromast: redis error:', err.message);
  });

  const store: KVStore = {
    async get(key) {
      return await client.get(key);
    },
    async put(key, value) {
      await client.set(key, value);
    },
    async delete(key) {
      await client.del(key);
    },
  };

  cached = { url, store };
  return store;
}

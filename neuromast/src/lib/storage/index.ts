// Runtime-agnostic key-value storage for neuromast's queue.
//
// The queue code (`../queue.ts`) never touches a runtime-specific binding
// — it takes a `KVStore` and works with anything that exposes the three
// methods below. This file's `getQueueStore(env)` is the only place that
// knows how to turn a runtime env object into a concrete KVStore, so
// adding a new backend is a single implementation file + a single case
// in the factory switch.
//
// Supported backends:
//   - cloudflare-kv  (Webflow Cloud / direct Cloudflare Workers)
//   - redis          (Railway / Fly / Render / any Node-runtime deploy)
//   - memory         (local `astro dev` + tests; non-persistent)

/// Minimum surface the queue needs. Cloudflare's `KVNamespace` is
/// structurally compatible (its `get`/`put`/`delete` are a strict superset),
/// so a raw binding passes through without a wrapper.
export interface KVStore {
  get(key: string): Promise<string | null>;
  put(key: string, value: string): Promise<void>;
  delete(key: string): Promise<void>;
}

/// Environment shape the factory reads. Each backend has its own optional
/// inputs; `STORAGE_KIND` is an explicit override when auto-detection would
/// ambiguously pick the wrong one (e.g. both QUEUE and REDIS_URL set).
export interface StorageEnv {
  QUEUE?: KVStore;               // Cloudflare KV binding (Workers runtime)
  REDIS_URL?: string;            // `redis://…` connection string (Node runtime)
  STORAGE_KIND?: StorageKind;    // explicit override
}

export type StorageKind = 'cloudflare-kv' | 'redis' | 'memory';

/// Resolve a `KVStore` from the runtime env.
///
/// Precedence:
///   1. `STORAGE_KIND` env var, if set and recognized
///   2. Auto-detect:
///        - `QUEUE` binding present → cloudflare-kv
///        - `REDIS_URL` set          → redis
///        - neither                  → memory (dev fallback, with warning)
///
/// Async because the Redis backend is dynamic-imported — keeps `ioredis`
/// and its Node-built-in deps out of the Cloudflare Workers bundle.
export async function getQueueStore(env: StorageEnv): Promise<KVStore> {
  const kind = env.STORAGE_KIND ?? detectKind(env);
  switch (kind) {
    case 'cloudflare-kv':
      if (!env.QUEUE) {
        throw new Error(
          'neuromast: STORAGE_KIND=cloudflare-kv but no QUEUE binding — ' +
          'check wrangler.json / Webflow Cloud project bindings.'
        );
      }
      return env.QUEUE;
    case 'redis': {
      if (!env.REDIS_URL) {
        throw new Error(
          'neuromast: STORAGE_KIND=redis but REDIS_URL is not set — ' +
          'Railway provisions this automatically when you add the Redis plugin.'
        );
      }
      const { createRedisKVStore } = await import('./redis');
      return createRedisKVStore(env.REDIS_URL);
    }
    case 'memory':
      return getMemoryStore();
    default:
      throw new Error(`neuromast: unknown STORAGE_KIND "${kind as string}"`);
  }
}

/// Extract the runtime env object from an Astro `locals`. Two shapes to
/// handle:
///   - Cloudflare Workers: `locals.runtime.env` carries bindings + secrets
///   - Node (standalone): `locals.runtime.env` *may* mirror `process.env`
///     depending on adapter version — fall back to `process.env` directly
///     if it's missing.
///
/// Routes call this once at the top of their handler and narrow the
/// result to their expected shape.
export function resolveEnv(locals: unknown): StorageEnv & Record<string, unknown> {
  const L = locals as { runtime?: { env?: Record<string, unknown> } } | undefined;
  if (L?.runtime?.env) return L.runtime.env as StorageEnv & Record<string, unknown>;
  // Node path. `typeof process` short-circuits cleanly in Workers bundles
  // where `process` is undeclared — Vite doesn't auto-polyfill here.
  if (typeof process !== 'undefined' && process.env) {
    return process.env as unknown as StorageEnv & Record<string, unknown>;
  }
  return {} as StorageEnv & Record<string, unknown>;
}

function detectKind(env: StorageEnv): StorageKind {
  if (env.QUEUE) return 'cloudflare-kv';
  if (env.REDIS_URL) return 'redis';
  warnMemoryFallback();
  return 'memory';
}

let memoryWarned = false;
function warnMemoryFallback(): void {
  if (memoryWarned) return;
  memoryWarned = true;
  console.warn(
    'neuromast: no storage backend configured (no QUEUE binding, no REDIS_URL); ' +
    'falling back to in-memory store. Data will not survive a restart.'
  );
}

// Lazy-init the memory store so its allocation cost only happens when it's
// actually used. Also means the Cloudflare bundle — where detectKind
// never returns 'memory' — can drop it entirely via tree-shaking.
let memoryStoreSingleton: KVStore | null = null;
function getMemoryStore(): KVStore {
  if (!memoryStoreSingleton) {
    memoryStoreSingleton = new MemoryKVStore();
  }
  return memoryStoreSingleton;
}

class MemoryKVStore implements KVStore {
  private data = new Map<string, string>();
  async get(key: string): Promise<string | null> {
    return this.data.get(key) ?? null;
  }
  async put(key: string, value: string): Promise<void> {
    this.data.set(key, value);
  }
  async delete(key: string): Promise<void> {
    this.data.delete(key);
  }
}

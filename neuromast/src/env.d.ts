/// <reference types="astro/client" />
/// <reference types="@cloudflare/workers-types" />

type Runtime = import('@astrojs/cloudflare').Runtime<Env>;

declare namespace App {
  interface Locals extends Runtime {}
}

interface Env {
  // Structurally typed key-value store; Cloudflare's KVNamespace satisfies
  // this, as would any other runtime's KV binding. Inline-import keeps this
  // .d.ts file ambient (no top-level import statements).
  QUEUE: import('./lib/queue').KVStore;
  POLL_TOKEN: string;
  SHARED_SECRET?: string;
  // Per-source signing config, looked up dynamically as HOOK_SCHEME_<SOURCE>
  // and HOOK_SECRET_<SOURCE>. Indexed access below keeps TS happy.
  [key: string]: unknown;
}

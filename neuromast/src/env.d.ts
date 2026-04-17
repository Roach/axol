/// <reference types="astro/client" />
/// <reference types="@cloudflare/workers-types" />

type Runtime = import('@astrojs/cloudflare').Runtime<Env>;

declare namespace App {
  interface Locals extends Runtime {}
}

interface Env {
  QUEUE: KVNamespace;
  POLL_TOKEN: string;
  SHARED_SECRET?: string;
  // Per-source signing config, looked up dynamically as HOOK_SCHEME_<SOURCE>
  // and HOOK_SECRET_<SOURCE>. Indexed access below keeps TS happy.
  [key: string]: unknown;
}

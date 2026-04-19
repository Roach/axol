// Per-service defaults for the approval flow.
//
// Config comes from a single env var `SERVICES_CONFIG` holding JSON —
// parsed once at module load and cached in memory. Why env var and not a
// bundled file: Cloudflare Workers doesn't have a conventional filesystem
// at runtime, and the Node-standalone adapters (Railway/Fly/Render) want
// to avoid reading files out of the bundle path. An env var works
// uniformly across every platform neuromast's docs cover.
//
// Shape:
//   {
//     "github-actions": { "hold_default": 20, "expires_default_s": 600 },
//     "slack-command":  { "hold_default":  2, "expires_default_s": 30  }
//   }
//
// Unknown services get global defaults. Per-request values always win
// over both per-service and global defaults.

import { DEFAULT_EXPIRES_MS, MAX_HOLD_SECONDS } from './permissions';

export interface ServiceDefaults {
  hold_default?: number;        // seconds; clamped to [0, MAX_HOLD_SECONDS]
  expires_default_s?: number;   // seconds; clamped by resolveExpiresAt at use site
}

export interface ResolvedServiceDefaults {
  holdSeconds: number;
  expiresMs: number;
}

let cache: Record<string, ServiceDefaults> | null = null;
let cacheSource: string | undefined;

function loadMap(raw: string | undefined): Record<string, ServiceDefaults> {
  if (!raw || raw.trim() === '') return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      console.warn('neuromast: SERVICES_CONFIG must be a JSON object; ignoring');
      return {};
    }
    return parsed as Record<string, ServiceDefaults>;
  } catch (err) {
    console.warn('neuromast: SERVICES_CONFIG is not valid JSON; ignoring', err);
    return {};
  }
}

/// Look up defaults for `source`, with global fallbacks. Returns resolved
/// numbers (no undefined) so call sites don't have to layer three checks.
export function defaultsFor(
  source: string | undefined,
  rawConfig: string | undefined,
): ResolvedServiceDefaults {
  if (cache === null || cacheSource !== rawConfig) {
    cache = loadMap(rawConfig);
    cacheSource = rawConfig;
  }
  const service = source && cache[source] ? cache[source] : undefined;
  const hold = Math.max(
    0,
    Math.min(MAX_HOLD_SECONDS, Number(service?.hold_default ?? 0)),
  );
  const expiresS = Number(service?.expires_default_s ?? DEFAULT_EXPIRES_MS / 1000);
  return {
    holdSeconds: Number.isFinite(hold) ? hold : 0,
    expiresMs: Date.now() + (Number.isFinite(expiresS) ? expiresS : DEFAULT_EXPIRES_MS / 1000) * 1000,
  };
}

/// Test helper — resets the module cache so tests can feed new configs
/// without process restart.
export function __resetServicesCache(): void {
  cache = null;
  cacheSource = undefined;
}

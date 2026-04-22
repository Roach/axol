// POST /api/hooks/{source}
//
// Per-source auth, resolved in order:
//   1. HOOK_SECRET_<SOURCE> set → HMAC verify. Scheme is taken from
//      HOOK_SCHEME_<SOURCE> if set; otherwise it defaults to the source
//      name when that name is a known scheme (github/stripe/generic).
//   2. SHARED_SECRET set and ?key matches → accept (fallback for senders
//      that can't sign).
//   3. Reject with 401.
//
// On accept, the raw JSON body is parked in the KV queue under the source
// tag; the local forwarder pulls it and posts it to Axol verbatim.

import type { APIRoute } from 'astro';
import { enqueue } from '../../../lib/queue';
import { getQueueStore, resolveEnv, type StorageEnv } from '../../../lib/storage';
import { verify, timingSafeEqualString, isKnownScheme } from '../../../lib/hmac';

export const prerender = false;

// Webhook payloads in the wild (GitHub PR events with a large diff summary,
// Stripe event objects) stay comfortably under ~256 KB. 1 MB is a generous
// ceiling that still rejects garbage uploads before they consume KV quota.
const MAX_BODY_BYTES = 1_000_000;

export const POST: APIRoute = async ({ params, request, locals }) => {
  const source = String(params.source ?? '').toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(source)) {
    return new Response(null, { status: 404 });
  }

  const env = resolveEnv(locals) as unknown as StorageEnv & {
    SHARED_SECRET?: string;
    [key: string]: unknown;
  };

  // Quick pre-check via Content-Length; the authoritative check below still
  // runs after we read the body (clients can lie or omit the header).
  const declared = Number(request.headers.get('content-length') ?? '');
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    return new Response(null, { status: 413 });
  }

  const rawBody = await request.text();
  if (rawBody.length === 0) return new Response(null, { status: 400 });
  if (rawBody.length > MAX_BODY_BYTES) return new Response(null, { status: 413 });

  // Tier 1 — per-source HMAC.
  const schemeKey = `HOOK_SCHEME_${source.toUpperCase()}`;
  const secretKey = `HOOK_SECRET_${source.toUpperCase()}`;
  const explicitScheme = typeof env[schemeKey] === 'string' ? (env[schemeKey] as string) : undefined;
  const secret = typeof env[secretKey] === 'string' ? (env[secretKey] as string) : undefined;
  // If the scheme wasn't set explicitly, default it to the source name when
  // that name is already a known scheme — the common case (a `github` source
  // using the `github` scheme) then needs only HOOK_SECRET_GITHUB to work.
  const scheme = explicitScheme ?? (secret && isKnownScheme(source) ? source : undefined);

  if (scheme) {
    const result = await verify(scheme, secret, request, rawBody);
    if (!result.ok) {
      console.log(`neuromast: reject ${source} scheme=${scheme} reason=${result.reason}`);
      return new Response(null, { status: 401 });
    }
  } else {
    // Tier 2 — shared query key.
    const url = new URL(request.url);
    const key = url.searchParams.get('key') ?? '';
    if (!env.SHARED_SECRET || !timingSafeEqualString(key, env.SHARED_SECRET)) {
      console.log(`neuromast: reject ${source} reason=no-auth`);
      return new Response(null, { status: 401 });
    }
  }

  let body: unknown;
  try {
    body = JSON.parse(rawBody);
  } catch {
    return new Response(null, { status: 400 });
  }

  await enqueue(await getQueueStore(env), { source, body });
  return new Response(null, { status: 204 });
};

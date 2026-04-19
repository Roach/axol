// POST /api/permission/{source}
//
// Approval-flow intake. Same auth ladder as /api/hooks/{source}:
//   1. HOOK_SCHEME_<SOURCE> + HOOK_SECRET_<SOURCE> → HMAC verify
//   2. SHARED_SECRET + ?key                        → accept
// On accept, stash a pending record and enqueue a `kind: "permission"`
// envelope on the main queue so the forwarder picks it up alongside
// regular alerts. If the request set `hold`, wait up to N seconds for
// the user's decision and return it inline; otherwise 202-accepted and
// rely on GET /api/decision/<id> polling or a webhook callback.

import type { APIRoute } from 'astro';
import { enqueue } from '../../../lib/queue';
import {
  DEFAULT_EXPIRES_MS,
  MAX_HOLD_SECONDS,
  putPending,
  resolveExpiresAt,
  waitForDecision,
} from '../../../lib/permissions';
import { defaultsFor } from '../../../lib/services';
import { getQueueStore, resolveEnv, type StorageEnv } from '../../../lib/storage';
import { verify, timingSafeEqualString } from '../../../lib/hmac';

export const prerender = false;

const MAX_BODY_BYTES = 256_000;  // tighter than the webhook intake — permission payloads are small

export const POST: APIRoute = async ({ params, request, locals }) => {
  const source = String(params.source ?? '').toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(source)) {
    return new Response(null, { status: 404 });
  }

  const env = resolveEnv(locals) as unknown as StorageEnv & {
    SHARED_SECRET?: string;
    SERVICES_CONFIG?: string;
    [key: string]: unknown;
  };

  const declared = Number(request.headers.get('content-length') ?? '');
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    return new Response(null, { status: 413 });
  }

  const rawBody = await request.text();
  if (rawBody.length === 0) return new Response(null, { status: 400 });
  if (rawBody.length > MAX_BODY_BYTES) return new Response(null, { status: 413 });

  // Auth — copied from hooks intake so operators have one mental model.
  const schemeKey = `HOOK_SCHEME_${source.toUpperCase()}`;
  const secretKey = `HOOK_SECRET_${source.toUpperCase()}`;
  const scheme = typeof env[schemeKey] === 'string' ? (env[schemeKey] as string) : undefined;
  const secret = typeof env[secretKey] === 'string' ? (env[secretKey] as string) : undefined;
  if (scheme) {
    const result = await verify(scheme, secret, request, rawBody);
    if (!result.ok) {
      console.log(`neuromast: permission reject ${source} scheme=${scheme} reason=${result.reason}`);
      return new Response(null, { status: 401 });
    }
  } else {
    const url = new URL(request.url);
    const key = url.searchParams.get('key') ?? '';
    if (!env.SHARED_SECRET || !timingSafeEqualString(key, env.SHARED_SECRET)) {
      console.log(`neuromast: permission reject ${source} reason=no-auth`);
      return new Response(null, { status: 401 });
    }
  }

  let body: Record<string, unknown>;
  try {
    const parsed = JSON.parse(rawBody);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return new Response(null, { status: 400 });
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return new Response(null, { status: 400 });
  }

  const requestId = typeof body.request_id === 'string' && body.request_id.length > 0
    ? body.request_id
    : crypto.randomUUID();
  const toolName = typeof body.tool_name === 'string' ? body.tool_name : null;
  if (!toolName) {
    return jsonError(400, 'tool_name is required');
  }

  // Resolve hold + expires_at, layering per-service defaults under
  // per-request overrides.
  const defaults = defaultsFor(source, env.SERVICES_CONFIG);
  const now = Date.now();
  let expiresAt: number;
  try {
    expiresAt = body.expires_at !== undefined
      ? resolveExpiresAt(body.expires_at, now)
      : (defaults.expiresMs > now
          ? defaults.expiresMs
          : now + DEFAULT_EXPIRES_MS);
  } catch (err) {
    return jsonError(400, (err as Error).message);
  }

  let holdSeconds = defaults.holdSeconds;
  if (body.hold !== undefined) {
    const h = Number(body.hold);
    if (!Number.isFinite(h) || h < 0) {
      return jsonError(400, 'hold: must be a non-negative number of seconds');
    }
    holdSeconds = Math.min(MAX_HOLD_SECONDS, h);
  }

  // The envelope the forwarder will pick up and POST to Axol's
  // /permission endpoint. Matches Claude Code's PermissionRequest shape
  // so Axol's existing handler accepts it without a second code path.
  const envelope: Record<string, unknown> = {
    kind: 'permission',
    request_id: requestId,
    tool_name: toolName,
    tool_input: body.tool_input ?? {},
    source,
  };
  if (typeof body.session_id === 'string') envelope.session_id = body.session_id;
  if (typeof body.cwd === 'string') envelope.cwd = body.cwd;
  if (typeof body.session_hint === 'string') envelope.session_hint = body.session_hint;

  const store = await getQueueStore(env);
  await putPending(store, {
    request_id: requestId,
    envelope,
    createdAt: now,
    expiresAt,
  });
  await enqueue(store, { source: `permission:${source}`, body: envelope });

  // Hold path — best-effort inline wait. On KV consistency gaps this can
  // time out even when the decision landed; caller falls through to the
  // same 202 shape and polls /api/decision/<id>.
  if (holdSeconds > 0) {
    const decision = await waitForDecision(store, requestId, holdSeconds);
    if (decision) {
      return new Response(
        JSON.stringify({
          request_id: requestId,
          status: decision.behavior,
          decided_at: new Date(decision.decidedAt).toISOString(),
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      );
    }
  }

  return new Response(
    JSON.stringify({
      request_id: requestId,
      status: 'pending',
      expires_at: new Date(expiresAt).toISOString(),
    }),
    { status: 202, headers: { 'content-type': 'application/json' } },
  );
};

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

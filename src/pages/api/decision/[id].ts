// GET  /api/decision/{id}       — public, returns { status, ... }
// POST /api/decision/{id}       — bearer-gated (POLL_TOKEN), used by
//                                 lateral-line to write the user's answer
//
// GET is intentionally unauthenticated: the `id` is a random UUID
// minted by the intake and shared only with the caller who submitted
// it, so possession of the id IS the auth. This lets tight-deadline
// callers (GitHub Actions etc.) poll without managing an extra secret.
// The write side is gated — only the forwarder may record decisions.
//
// GET optionally supports ?wait=<seconds> for long-polling; capped at
// MAX_HOLD_SECONDS to stay inside Cloudflare Workers' idle budget.

import type { APIRoute } from 'astro';
import {
  MAX_HOLD_SECONDS,
  putDecision,
  statusOf,
  waitForDecision,
  type Decision,
} from '../../../lib/permissions';
import { getQueueStore, resolveEnv, type StorageEnv } from '../../../lib/storage';
import { timingSafeEqualString } from '../../../lib/hmac';

export const prerender = false;

const ID_RE = /^[A-Za-z0-9_-]{8,64}$/;

export const GET: APIRoute = async ({ params, request, locals }) => {
  const id = String(params.id ?? '');
  if (!ID_RE.test(id)) return notFound();

  const env = resolveEnv(locals) as unknown as StorageEnv;
  const store = await getQueueStore(env);
  const now = Date.now();

  const url = new URL(request.url);
  const waitParam = url.searchParams.get('wait');
  const waitSeconds = waitParam != null ? Math.min(MAX_HOLD_SECONDS, Math.max(0, Number(waitParam))) : 0;

  // Fast path — already decided.
  const status = await statusOf(store, id, now);
  if (status.kind === 'decided') return decidedResponse(id, status.decision.behavior, status.decision.decidedAt);
  if (status.kind === 'unknown') return pendingResponse(id, null, 'unknown');

  if (waitSeconds > 0) {
    const decision = await waitForDecision(store, id, waitSeconds);
    if (decision) return decidedResponse(id, decision.behavior, decision.decidedAt);
  }

  // Still pending — echo expires_at so the caller can plan its next poll.
  return pendingResponse(id, status.pending.expiresAt, 'pending');
};

export const POST: APIRoute = async ({ params, request, locals }) => {
  const id = String(params.id ?? '');
  if (!ID_RE.test(id)) return notFound();

  const env = resolveEnv(locals) as unknown as StorageEnv & { POLL_TOKEN?: string };
  if (!checkBearer(request, env.POLL_TOKEN)) {
    return new Response(null, { status: 401 });
  }

  let body: { behavior?: unknown };
  try {
    body = (await request.json()) as { behavior?: unknown };
  } catch {
    return jsonError(400, 'body must be JSON');
  }

  const behavior = body.behavior;
  if (behavior !== 'allow' && behavior !== 'deny' && behavior !== 'expired') {
    return jsonError(400, 'behavior must be "allow" | "deny" | "expired"');
  }

  const store = await getQueueStore(env);
  const rec = await putDecision(store, id, behavior as Decision, Date.now());
  return new Response(
    JSON.stringify({
      request_id: id,
      status: rec.behavior,
      decided_at: new Date(rec.decidedAt).toISOString(),
    }),
    { status: 200, headers: { 'content-type': 'application/json' } },
  );
};

function decidedResponse(id: string, behavior: Decision, decidedAt: number): Response {
  return new Response(
    JSON.stringify({
      request_id: id,
      status: behavior,
      decided_at: new Date(decidedAt).toISOString(),
    }),
    { status: 200, headers: { 'content-type': 'application/json' } },
  );
}

function pendingResponse(id: string, expiresAt: number | null, kind: 'pending' | 'unknown'): Response {
  const payload: Record<string, unknown> = { request_id: id, status: kind };
  if (expiresAt != null) payload.expires_at = new Date(expiresAt).toISOString();
  const status = kind === 'unknown' ? 404 : 200;
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function notFound(): Response {
  return new Response(
    JSON.stringify({ error: 'malformed request id' }),
    { status: 400, headers: { 'content-type': 'application/json' } },
  );
}

function jsonError(status: number, message: string): Response {
  return new Response(
    JSON.stringify({ error: message }),
    { status, headers: { 'content-type': 'application/json' } },
  );
}

function checkBearer(request: Request, expected: string | undefined): boolean {
  if (!expected) return false;
  const header = request.headers.get('authorization') ?? '';
  if (!header.toLowerCase().startsWith('bearer ')) return false;
  const token = header.slice('bearer '.length).trim();
  return timingSafeEqualString(token, expected);
}

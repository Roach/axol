// GET /api/pull?since=<cursor>
//
// Returns up to 25 queued items with ids > cursor, plus a nextCursor the
// forwarder should send back on the next pull. Bearer-token gated.

import type { APIRoute } from 'astro';
import { pullSince } from '../../lib/queue';
import { timingSafeEqualString } from '../../lib/hmac';

export const prerender = false;

export const GET: APIRoute = async ({ request, locals }) => {
  const env = locals.runtime.env as unknown as {
    QUEUE: KVNamespace;
    POLL_TOKEN: string;
  };

  if (!checkBearer(request, env.POLL_TOKEN)) {
    return new Response(null, { status: 401 });
  }

  const url = new URL(request.url);
  const since = url.searchParams.get('since');
  const { items, nextCursor } = await pullSince(env, since && since.length > 0 ? since : null);

  return new Response(JSON.stringify({ items, nextCursor }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
};

function checkBearer(request: Request, expected: string | undefined): boolean {
  if (!expected) return false;
  const header = request.headers.get('authorization') ?? '';
  if (!header.toLowerCase().startsWith('bearer ')) return false;
  const token = header.slice('bearer '.length).trim();
  return timingSafeEqualString(token, expected);
}

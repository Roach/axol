// POST /api/ack  { ids: string[] }
//
// Deletes acked items from KV and trims the index. Bearer-token gated.

import type { APIRoute } from 'astro';
import { ackIds } from '../../lib/queue';
import { timingSafeEqualString } from '../../lib/hmac';

export const prerender = false;

export const POST: APIRoute = async ({ request, locals }) => {
  const env = locals.runtime.env as unknown as {
    QUEUE: KVNamespace;
    POLL_TOKEN: string;
  };

  if (!checkBearer(request, env.POLL_TOKEN)) {
    return new Response(null, { status: 401 });
  }

  let payload: { ids?: unknown };
  try {
    payload = (await request.json()) as { ids?: unknown };
  } catch {
    return new Response(null, { status: 400 });
  }

  if (!Array.isArray(payload.ids) || !payload.ids.every((v) => typeof v === 'string')) {
    return new Response(null, { status: 400 });
  }

  await ackIds(env, payload.ids as string[]);
  return new Response(null, { status: 204 });
};

function checkBearer(request: Request, expected: string | undefined): boolean {
  if (!expected) return false;
  const header = request.headers.get('authorization') ?? '';
  if (!header.toLowerCase().startsWith('bearer ')) return false;
  const token = header.slice('bearer '.length).trim();
  return timingSafeEqualString(token, expected);
}

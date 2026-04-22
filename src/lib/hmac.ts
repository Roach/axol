// Per-scheme HMAC verifiers for inbound webhook auth. All schemes run over
// the raw request body bytes using Web Crypto's `subtle` API, which is
// available in every modern edge runtime (Workers, Deno, Node 20+).
//
// Supported:
//   github  — X-Hub-Signature-256: sha256=<hex> over body
//   stripe  — Stripe-Signature: t=<ts>,v1=<hex> over `<ts>.<body>`, 300s replay window
//   generic — X-Signature-256: sha256=<hex> over body (our own convention)
//
// Optional replay protection on github/generic: if the sender also includes
// `X-Signature-Timestamp: <unix-seconds>`, the server verifies it's within the
// 300s window AND HMACs `<ts>.<body>` instead of `<body>` alone — giving
// Stripe-style replay resistance without breaking senders that don't sign a
// timestamp.

export const KNOWN_SCHEMES = ['github', 'stripe', 'generic'] as const;
export type Scheme = (typeof KNOWN_SCHEMES)[number];

/// True when `name` is one of the built-in HMAC schemes (github / stripe / generic).
/// Used by the hooks + permission handlers to default `HOOK_SCHEME_<SOURCE>`
/// to the source name when the operator didn't set it explicitly — so a lone
/// `HOOK_SECRET_GITHUB` is enough to opt a `github`-named source into HMAC.
export function isKnownScheme(name: string): name is Scheme {
  return (KNOWN_SCHEMES as readonly string[]).includes(name);
}

export interface VerifyResult {
  ok: boolean;
  reason?: string;
}

const REPLAY_WINDOW_SECONDS = 300;

// Returns {payload, reason?} — payload is what should be HMAC'd. If the caller
// supplied a timestamp header, we check it's fresh and fold it into the
// payload; otherwise we fall back to the body alone. `reason` is only set
// when we want to reject outright (stale timestamp, malformed timestamp).
function payloadWithOptionalTimestamp(
  req: Request,
  body: string,
): { payload: string; reason?: string } {
  const ts = req.headers.get('x-signature-timestamp');
  if (!ts) return { payload: body };
  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum)) return { payload: body, reason: 'malformed-timestamp' };
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - tsNum) > REPLAY_WINDOW_SECONDS) {
    return { payload: body, reason: 'timestamp-out-of-window' };
  }
  return { payload: `${ts}.${body}` };
}

export async function verify(
  scheme: string,
  secret: string | undefined,
  request: Request,
  rawBody: string,
): Promise<VerifyResult> {
  if (!secret) return { ok: false, reason: 'missing-secret' };
  switch (scheme) {
    case 'github':  return verifyGithub(secret, request, rawBody);
    case 'stripe':  return verifyStripe(secret, request, rawBody);
    case 'generic': return verifyGeneric(secret, request, rawBody);
    default:        return { ok: false, reason: 'unknown-scheme' };
  }
}

async function verifyGithub(secret: string, req: Request, body: string): Promise<VerifyResult> {
  const header = req.headers.get('x-hub-signature-256');
  if (!header || !header.startsWith('sha256=')) return { ok: false, reason: 'missing-signature' };
  const expected = header.slice('sha256='.length);
  const { payload, reason } = payloadWithOptionalTimestamp(req, body);
  if (reason) return { ok: false, reason };
  const actual = await hmacHex(secret, payload);
  return timingSafeEqualHex(expected, actual)
    ? { ok: true }
    : { ok: false, reason: 'bad-signature' };
}

async function verifyStripe(secret: string, req: Request, body: string): Promise<VerifyResult> {
  const header = req.headers.get('stripe-signature');
  if (!header) return { ok: false, reason: 'missing-signature' };
  const parts: Record<string, string[]> = {};
  for (const pair of header.split(',')) {
    const [k, v] = pair.split('=', 2);
    if (!k || !v) continue;
    (parts[k.trim()] ||= []).push(v.trim());
  }
  const ts = parts['t']?.[0];
  const sigs = parts['v1'] ?? [];
  if (!ts || sigs.length === 0) return { ok: false, reason: 'malformed-signature' };

  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum)) return { ok: false, reason: 'malformed-timestamp' };
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - tsNum) > REPLAY_WINDOW_SECONDS) return { ok: false, reason: 'timestamp-out-of-window' };

  const expected = await hmacHex(secret, `${ts}.${body}`);
  // Stripe rotates keys by listing multiple v1 values; any match is good.
  for (const sig of sigs) {
    if (timingSafeEqualHex(sig, expected)) return { ok: true };
  }
  return { ok: false, reason: 'bad-signature' };
}

async function verifyGeneric(secret: string, req: Request, body: string): Promise<VerifyResult> {
  const header = req.headers.get('x-signature-256');
  if (!header || !header.startsWith('sha256=')) return { ok: false, reason: 'missing-signature' };
  const expected = header.slice('sha256='.length);
  const { payload, reason } = payloadWithOptionalTimestamp(req, body);
  if (reason) return { ok: false, reason };
  const actual = await hmacHex(secret, payload);
  return timingSafeEqualHex(expected, actual)
    ? { ok: true }
    : { ok: false, reason: 'bad-signature' };
}

async function hmacHex(secret: string, data: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sigBuf = await crypto.subtle.sign('HMAC', key, enc.encode(data));
  return bufferToHex(sigBuf);
}

function bufferToHex(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let out = '';
  for (const b of bytes) out += b.toString(16).padStart(2, '0');
  return out;
}

function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

export function timingSafeEqualString(a: string, b: string): boolean {
  return timingSafeEqualHex(a, b);
}

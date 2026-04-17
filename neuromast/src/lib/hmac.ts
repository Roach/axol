// Per-scheme HMAC verifiers for inbound webhook auth. All schemes run over
// the raw request body bytes; Web Crypto's `subtle` is available natively
// in Cloudflare Workers.
//
// Supported:
//   github  — X-Hub-Signature-256: sha256=<hex> over body
//   stripe  — Stripe-Signature: t=<ts>,v1=<hex> over `<ts>.<body>`, 300s replay window
//   generic — X-Signature-256: sha256=<hex> over body (our own convention)

export type Scheme = 'github' | 'stripe' | 'generic';

export interface VerifyResult {
  ok: boolean;
  reason?: string;
}

const REPLAY_WINDOW_SECONDS = 300;

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
  const actual = await hmacHex(secret, body);
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
  const actual = await hmacHex(secret, body);
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

# neuromast — Axol's cloud webhook endpoint

A minimal serverless webhook intake that accepts signed third-party webhooks and parks them in a short-TTL queue for Axol's local forwarder (`lateral-line/`) to pull.

Named after the sensory cell clusters along a fish's lateral line — each hook URL is one neuromast picking up signals from the outside world.

**Deploy guides** (platform-specific setup):
- Webflow Cloud — [`docs/deploy-webflow.html`](../docs/deploy-webflow.html)
- Railway — [`docs/deploy-railway.html`](../docs/deploy-railway.html)
- Fly.io — [`docs/deploy-fly.html`](../docs/deploy-fly.html)
- Render — [`docs/deploy-render.html`](../docs/deploy-render.html)
- Cloudflare (direct) — [`docs/deploy-cloudflare.html`](../docs/deploy-cloudflare.html)

The implementation currently targets Astro + Cloudflare Workers (which is what Webflow Cloud provides under the hood), but the routes and queue helpers are small enough that porting to another edge runtime is mostly swapping the KV binding for another key-value store.

## Routes

| Method | Path                   | Auth                                    | Purpose                                 |
| ------ | ---------------------- | --------------------------------------- | --------------------------------------- |
| POST   | `/app/api/hooks/{source}`  | per-source HMAC, or `?key=<SHARED>`     | Enqueue a webhook body                  |
| GET    | `/app/api/pull?since=...`  | `Authorization: Bearer <POLL_TOKEN>`    | Pull up to 25 pending items             |
| POST   | `/app/api/ack`             | `Authorization: Bearer <POLL_TOKEN>`    | Delete acked ids from the queue         |

`{source}` must match `^[a-z0-9][a-z0-9_-]{0,31}$` — it becomes the `source` field on the queued item and is how Axol's adapters can filter later (via `context.source` if you add it to the envelope).

## HMAC schemes

Set two env vars per signed source, where `<SOURCE>` is the URL segment uppercased (e.g. `HOOK_SCHEME_GITHUB`).

| Scheme    | Header                        | Signed input         | Notes                                     |
| --------- | ----------------------------- | -------------------- | ----------------------------------------- |
| `github`  | `X-Hub-Signature-256`         | raw body             | `sha256=<hex>` format                     |
| `stripe`  | `Stripe-Signature`            | `<ts>.<body>`        | 300s replay window; tolerates key rotation (multiple `v1=` values) |
| `generic` | `X-Signature-256`             | raw body             | `sha256=<hex>`; our own convention for ad-hoc senders |

**Optional replay protection** for `github` and `generic`: if the sender also sends `X-Signature-Timestamp: <unix-seconds>`, the server verifies it's within a 300-second window and HMACs `<ts>.<body>` instead of `<body>` alone. Stripe already bakes the timestamp into `Stripe-Signature`, so this only applies to the other two schemes.

If no per-source scheme is configured, the endpoint falls back to `?key=<SHARED_SECRET>`.

## Limits

- **Body size.** `POST /app/api/hooks/{source}` rejects payloads larger than 1 MB with `HTTP 413`. The check runs both on the `Content-Length` header and after reading, so a lying Content-Length won't slip through. Real-world webhooks (GitHub PR events, Stripe event objects) sit well under this.
- **Queue depth.** The index is capped at the 100 most-recent items. Older unacked ids age out of the index; their stored bodies remain in KV until the backing store's own expiration kicks in.
- **Pull page size.** `/pull` returns at most 25 items per call. Drain by paginating with the returned `nextCursor`.

## Env vars

All env vars and secrets are set per-platform (in the Webflow Cloud dashboard for that target — see the deploy guide). The worker itself just reads them off the runtime `env` object.

| Name                           | Required                           |
| ------------------------------ | ---------------------------------- |
| `POLL_TOKEN`                   | always — bearer for `/pull` + `/ack` |
| `SHARED_SECRET`                | only if you want the `?key` fallback for unsigned senders |
| `HOOK_SCHEME_<SOURCE>`         | per signed source                  |
| `HOOK_SECRET_<SOURCE>`         | per signed source                  |

## Deploy

See the platform-specific guide linked at the top of this README (currently: Webflow Cloud). All targets end at the same outcome — an HTTPS URL hosting the three routes under `/app/api/` and env vars set for `POLL_TOKEN`, `SHARED_SECRET`, and any `HOOK_SECRET_<SOURCE>` pairs you need.

Feed the deployed base URL (without the `/app` suffix) to `AXOL_CLOUD_URL` in the forwarder's environment — routes below are relative to it.

## Smoke tests

```sh
# Shared-key path
curl -X POST "$BASE/app/api/hooks/test?key=$SHARED_SECRET" \
     -H 'content-type: application/json' \
     -d '{"title":"hello","body":"from cloud"}'        # → 204

# HMAC path (github)
body='{"workflow_run":{"conclusion":"success","head_branch":"main","html_url":"https://example.com"}}'
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$HOOK_SECRET_GITHUB" -hex | awk '{print $2}')
curl -X POST "$BASE/app/api/hooks/github" \
     -H "X-Hub-Signature-256: sha256=$sig" \
     -H 'content-type: application/json' \
     -d "$body"                                         # → 204

# Pull
curl -H "Authorization: Bearer $POLL_TOKEN" "$BASE/app/api/pull"
```

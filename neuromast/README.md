# neuromast — Axol's cloud webhook endpoint

A minimal Astro + Cloudflare Workers app, deployed to Webflow Cloud, that accepts signed third-party webhooks and parks them in a KV queue for Axol's local forwarder (`lateral-line/`) to pull.

Named after the sensory cell clusters along a fish's lateral line — each hook URL is one neuromast picking up signals from the outside world.

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

If no per-source scheme is configured, the endpoint falls back to `?key=<SHARED_SECRET>`.

## Env vars

All env vars and secrets are set in the **Webflow Cloud dashboard** under your project's **Deployments → Environment Variables**. There is no CLI for this (as of CLI v1.14), and no Cloudflare account is involved — Webflow Cloud manages the underlying Worker and KV namespace.

| Name                           | Required                           |
| ------------------------------ | ---------------------------------- |
| `POLL_TOKEN`                   | always — bearer for `/pull` + `/ack` |
| `SHARED_SECRET`                | only if you want the `?key` fallback for unsigned senders |
| `HOOK_SCHEME_<SOURCE>`         | per signed source                  |
| `HOOK_SECRET_<SOURCE>`         | per signed source                  |

## Deploy

```sh
npm install
npm install -g @webflow/webflow-cli
webflow cloud init          # bind to a Webflow site (writes siteId into webflow.json)
webflow cloud deploy        # first deploy auto-creates the KV namespace
```

After the first deploy:

1. In the Webflow Cloud dashboard, set the env vars listed above.
2. Grab the real KV namespace id from the dashboard's KV section and paste it into **both** the `QUEUE` and `SESSION` entries in `wrangler.json` (we reuse one namespace; `SESSION` is a phantom binding the Astro Cloudflare adapter insists on).
3. `webflow cloud deploy` again with the real id.

The deploy output includes the URL where the worker is mounted (something like `https://<site>.webflow.io/app`). Feed that *without* the `/app` suffix to `AXOL_CLOUD_URL` in the forwarder's environment — routes below are relative to it.

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

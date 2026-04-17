# lateral-line — local forwarder

A ~50-line bash script that pulls queued webhooks from `neuromast/` and POSTs each one into Axol's loopback receiver (`127.0.0.1:47329`). Runs every 30 seconds via `launchd`.

Named after the lateral line nerve — the pathway that carries signals from a fish's neuromasts back to the brain.

## How it works

Per tick:

1. `GET {AXOL_CLOUD_URL}/app/api/pull?since={cursor}` with `Authorization: Bearer {AXOL_POLL_TOKEN}`.
2. For each `item` in the response, `POST item.body` (raw JSON) to `http://127.0.0.1:47329/`. Axol's existing adapter system handles translation.
3. For items that delivered successfully, `POST {AXOL_CLOUD_URL}/app/api/ack` with their ids so the cloud drops them.
4. Save the `nextCursor` to `~/Library/Application Support/Axol/lateral-line.cursor`.

**At-least-once delivery.** If Axol is down, items stay in KV and retry next tick. If the script crashes between forward and ack, you may see one duplicate bubble — acceptable for MVP.

## Dependencies

- `curl` (bundled with macOS)
- `jq` — `brew install jq`

## Install

```sh
cp com.axol.lateral-line.plist.example ~/Library/LaunchAgents/com.axol.lateral-line.plist
# Edit the copy:
#   Program       → absolute path to lateral-line.sh
#   AXOL_CLOUD_URL → your deployed neuromast URL
#   AXOL_POLL_TOKEN → the POLL_TOKEN you set in wrangler
launchctl load ~/Library/LaunchAgents/com.axol.lateral-line.plist
```

Verify it's running:

```sh
launchctl list | grep lateral-line
tail -f /tmp/axol-lateral-line.log
```

## Manual test

```sh
AXOL_CLOUD_URL=https://your-neuromast.webflow.app \
AXOL_POLL_TOKEN=... \
./lateral-line.sh
```

With Axol running and at least one item queued, you should see a bubble.

## Environment

| Name             | Default                                        | Purpose                       |
| ---------------- | ---------------------------------------------- | ----------------------------- |
| `AXOL_CLOUD_URL` | —                                              | Required. Base URL of neuromast. |
| `AXOL_POLL_TOKEN`| —                                              | Required. Bearer token.       |
| `AXOL_LOCAL_URL` | `http://127.0.0.1:47329/`                      | Override if Axol binds elsewhere. |
| `AXOL_STATE_DIR` | `$HOME/Library/Application Support/Axol`       | Cursor file location.         |

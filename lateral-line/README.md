# lateral-line — local forwarder

A ~50-line bash script that pulls queued webhooks from `neuromast/` and POSTs each one into Axol's loopback receiver (`127.0.0.1:47329`). Runs every minute via `launchd`.

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
AXOL_CLOUD_URL=https://your-site.webflow.io \
AXOL_POLL_TOKEN=your-bearer-token \
./install.sh
```

That renders the plist with absolute paths + your env, drops it into `~/Library/LaunchAgents/com.axol.lateral-line.plist` (owner-only `chmod 600` so the bearer token isn't world-readable), runs `chmod +x` on the forwarder script, and loads it. Re-running replaces the existing install.

Verify it's running:

```sh
launchctl list | grep lateral-line
tail -f ~/Library/Logs/Axol/lateral-line.log
```

To uninstall:

```sh
launchctl unload ~/Library/LaunchAgents/com.axol.lateral-line.plist
rm ~/Library/LaunchAgents/com.axol.lateral-line.plist
```

(`com.axol.lateral-line.plist.example` is still in the repo for reference if you'd rather hand-edit.)

## Robustness notes

- **Concurrent-run guard.** The script takes a `flock` (`lateral-line.lock` in the state dir) so overlapping launchd fires don't race on the cursor. macOS doesn't ship `flock(1)` by default — falls back to a noclobber symlink with a 10-minute stale-lock reaper.
- **Liveness probe.** Before hitting the cloud each tick, the script does a bare TCP connect to `127.0.0.1:47329`; if Axol isn't listening it bails cleanly, leaving items queued for the next run.
- **Atomic cursor write.** The cursor file is written via a `.tmp` + `mv` so a crash mid-write can't leave it truncated or corrupt. A malformed `nextCursor` from the cloud holds the previous cursor instead of advancing.

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

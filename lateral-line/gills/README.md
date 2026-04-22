# lateral-line gills

A small companion pattern for the `lateral-line` forwarder. Where `lateral-line.sh` drains the neuromast queue for webhook-driven alerts, gills handle the inverse case: services that don't (or can't) webhook you, so you have to pull them yourself.

Named for axolotls' signature feature — the three pairs of feathery external gills that wave rhythmically to sample the water around them. Same rhythmic sampling a polling loop does, same "stick out into the world and catch what's passing through" role.

Each gill is a short bash script that runs on its own `launchd` job, reads a credential from macOS Keychain, queries an upstream API, and POSTs each new item straight into Axol's loopback receiver at `http://127.0.0.1:47329/`. No neuromast involvement — gills are purely local, which means the credential never leaves your Mac.

## Bundled gills

| Gill | Upstream | Keychain service | Interval |
| --- | --- | --- | --- |
| `github-notifications` | GitHub [`GET /notifications`](https://docs.github.com/en/rest/activity/notifications) | `axol-github-pat` | 30s |

## Install a gill

One-time credential setup (uses a fine-grained PAT with **Notifications: read**):

```sh
security add-generic-password -a "$USER" -s axol-github-pat -w <your-token>
```

Install the launchd job:

```sh
./install.sh github-notifications
```

Tail the log to confirm samples are happening:

```sh
tail -f ~/Library/Logs/Axol/gill-github-notifications.log
```

Uninstall:

```sh
./install.sh github-notifications --uninstall
```

## Writing a new gill

A gill is any script that:

1. Sources `lib.sh` from the same directory.
2. Calls `gill_init "<name>"` first to claim the per-gill lock.
3. Reads its secret via `gill_keychain_secret "<service>"`.
4. Uses `gill_cursor_read` / `gill_cursor_write` for dedup.
5. Checks `gill_axol_up` before hitting the upstream (don't burn rate-limit budget when Axol is closed).
6. Builds one Axol envelope per new item and calls `gill_post_envelope "$json"`.

Minimum viable gill (~20 lines):

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
gill_init "example"
gill_axol_up || exit 0
token=$(gill_keychain_secret "axol-example-token") || exit 0
since=$(gill_cursor_read)
resp=$(curl -fsS -H "Authorization: Bearer $token" "https://api.example.com/items?since=$since")
echo "$resp" | jq -c '.items[]' | while read -r item; do
    title=$(jq -r '.title' <<<"$item")
    env=$(jq -n --arg t "$title" '{title:$t, body:"new item", icon:"bell"}')
    gill_post_envelope "$env" || exit 0
done
gill_cursor_write "$(date -u +%FT%TZ)"
```

Then `./install.sh example` picks up the new script automatically — the installer only requires `<name>.sh` to exist next to it; no registry file.

## Why gills live here instead of in neuromast

Gills intentionally skip the cloud round-trip because:

- **Credentials stay on-device.** A GitHub PAT has broad read access; leaving it in macOS Keychain is safer than parking it in a cloud env var.
- **Rate limits are per-token.** Polling from every running Mac is wasteful but harmless; polling from the cloud would still only give you one view but would require a queue fanout per device.
- **Lateral-line already runs here.** Adding another `launchd` plist next to `com.axol.lateral-line` fits the existing mental model — no new infra.

If you need multi-device fanout from a single token, the tradeoff tips toward a cloud-side plugin system on neuromast — not yet built.

#!/usr/bin/env bash
# lateral-line — pull queued webhooks from neuromast and forward each one
# to the local Axol receiver. Intended to run on launchd with
# StartInterval: 15. One pass per invocation; failures are no-ops so the
# next tick retries.
#
# Required env:
#   AXOL_CLOUD_URL   e.g. https://neuromast.example.webflow.app
#   AXOL_POLL_TOKEN  bearer token matching POLL_TOKEN on neuromast
#
# Optional env:
#   AXOL_LOCAL_URL   default http://127.0.0.1:47329/
#   AXOL_STATE_DIR   default $HOME/Library/Application Support/Axol
#   AXOL_LOG_DIR     default $HOME/Library/Logs/Axol

set -euo pipefail

: "${AXOL_CLOUD_URL:?set AXOL_CLOUD_URL}"
: "${AXOL_POLL_TOKEN:?set AXOL_POLL_TOKEN}"
LOCAL_URL="${AXOL_LOCAL_URL:-http://127.0.0.1:47329/}"
STATE_DIR="${AXOL_STATE_DIR:-$HOME/Library/Application Support/Axol}"
CURSOR_FILE="$STATE_DIR/lateral-line.cursor"
LOCK_FILE="$STATE_DIR/lateral-line.lock"

mkdir -p "$STATE_DIR"

# Serialize runs via a coarse file lock. launchd can fire a second invocation
# while the first is still polling; without this, both can write the cursor
# and clobber each other. `flock -n` bails silently when already held —
# the next tick will pick up.
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || exit 0
else
    # macOS doesn't ship flock(1) by default. Fall back to a best-effort
    # noclobber symlink lock; a stale link from a crashed run is cleared
    # after 10 minutes of inactivity.
    if ! (set -C; : >"$LOCK_FILE.pid") 2>/dev/null; then
        if [[ -n "$(find "$LOCK_FILE.pid" -mmin +10 2>/dev/null)" ]]; then
            rm -f "$LOCK_FILE.pid"
            (set -C; : >"$LOCK_FILE.pid") 2>/dev/null || exit 0
        else
            exit 0
        fi
    fi
    trap 'rm -f "$LOCK_FILE.pid"' EXIT
fi

SINCE="$(cat "$CURSOR_FILE" 2>/dev/null || printf '')"

# Quick liveness probe on the local receiver via bare TCP connect. If Axol
# is down we can skip the cloud round-trip entirely — items stay queued in
# neuromast and the next tick retries once she's back up. We check TCP
# reachability (not HTTP response) because Axol returns 400 for any probe
# payload that lacks a title.
LOCAL_HOST="$(printf '%s' "$LOCAL_URL" | sed -E 's|^https?://||' | cut -d/ -f1 | cut -d: -f1)"
LOCAL_PORT="$(printf '%s' "$LOCAL_URL" | sed -E 's|^https?://||' | cut -d/ -f1 | awk -F: '{print ($2=="" ? "47329" : $2)}')"
if ! (exec 3<>"/dev/tcp/$LOCAL_HOST/$LOCAL_PORT") 2>/dev/null; then
    echo "[$(date -u +%FT%TZ)] axol not listening on $LOCAL_HOST:$LOCAL_PORT; skipping pull" >&2
    exit 0
fi
exec 3>&- 3<&- 2>/dev/null || true

# 1. Pull. If the cloud is unreachable, exit cleanly — launchd will retry.
if ! resp=$(curl -fsS --max-time 10 \
                -H "Authorization: Bearer $AXOL_POLL_TOKEN" \
                "$AXOL_CLOUD_URL/app/api/pull?since=$SINCE"); then
    echo "[$(date -u +%FT%TZ)] pull failed; will retry next tick" >&2
    exit 0
fi

count=$(jq '.items | length' <<<"$resp")
if [[ "$count" -eq 0 ]]; then
    exit 0
fi

# 2. Forward each body. Only ack the ids that Axol actually accepted.
ids_json='[]'
while IFS= read -r row; do
    id=$(jq -r '.id' <<<"$row")
    body=$(jq -c '.body' <<<"$row")
    if curl -fsS --max-time 5 -o /dev/null \
            -X POST -H 'Content-Type: application/json' \
            --data "$body" "$LOCAL_URL"; then
        ids_json=$(jq --arg id "$id" '. + [$id]' <<<"$ids_json")
    else
        echo "[$(date -u +%FT%TZ)] local forward failed for id=$id; leaving in queue" >&2
    fi
done < <(jq -c '.items[]' <<<"$resp")

acked=$(jq 'length' <<<"$ids_json")
if [[ "$acked" -eq 0 ]]; then
    exit 0
fi

# 3. Ack delivered ids and advance the cursor to the last pulled id.
payload=$(jq -n --argjson ids "$ids_json" '{ids:$ids}')
curl -fsS --max-time 10 -o /dev/null \
     -H "Authorization: Bearer $AXOL_POLL_TOKEN" \
     -H 'Content-Type: application/json' \
     -X POST --data "$payload" "$AXOL_CLOUD_URL/app/api/ack"

# Extract + validate the next cursor before writing. Neuromast guarantees
# `nextCursor` is a string; anything else (null, missing, malformed JSON)
# means we should hold the previous cursor and retry next tick.
next_cursor=$(jq -r 'if .nextCursor and (.nextCursor | type == "string")
                     then .nextCursor else empty end' <<<"$resp")
if [[ -n "$next_cursor" ]]; then
    # Atomic replace so a crash mid-write can't truncate the cursor file.
    printf '%s' "$next_cursor" >"$CURSOR_FILE.tmp"
    mv "$CURSOR_FILE.tmp" "$CURSOR_FILE"
    echo "[$(date -u +%FT%TZ)] delivered=$acked/$count cursor=$next_cursor"
else
    echo "[$(date -u +%FT%TZ)] delivered=$acked/$count (no cursor advance — malformed response)" >&2
fi

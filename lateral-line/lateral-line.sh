#!/usr/bin/env bash
# lateral-line — pull queued webhooks from neuromast and forward each one
# to the local Axol receiver. Intended to run on launchd with
# StartInterval: 30. One pass per invocation; failures are no-ops so the
# next tick retries.
#
# Required env:
#   AXOL_CLOUD_URL   e.g. https://neuromast.example.webflow.app
#   AXOL_POLL_TOKEN  bearer token matching POLL_TOKEN on neuromast
#
# Optional env:
#   AXOL_LOCAL_URL   default http://127.0.0.1:47329/
#   AXOL_STATE_DIR   default $HOME/Library/Application Support/Axol

set -euo pipefail

: "${AXOL_CLOUD_URL:?set AXOL_CLOUD_URL}"
: "${AXOL_POLL_TOKEN:?set AXOL_POLL_TOKEN}"
LOCAL_URL="${AXOL_LOCAL_URL:-http://127.0.0.1:47329/}"
STATE_DIR="${AXOL_STATE_DIR:-$HOME/Library/Application Support/Axol}"
CURSOR_FILE="$STATE_DIR/lateral-line.cursor"

mkdir -p "$STATE_DIR"
SINCE="$(cat "$CURSOR_FILE" 2>/dev/null || printf '')"

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

jq -r '.nextCursor' <<<"$resp" > "$CURSOR_FILE"
echo "[$(date -u +%FT%TZ)] delivered=$acked/$count cursor=$(cat "$CURSOR_FILE")"

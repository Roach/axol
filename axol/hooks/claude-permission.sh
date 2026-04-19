#!/usr/bin/env bash
# Claude Code PermissionRequest hook → Axol permission bubble bridge.
#
# Only fires when Claude Code's own permission flow would prompt —
# reads the PermissionRequest JSON on stdin, POSTs it to Axol, and
# forwards Axol's response verbatim (shapes already match).
#
# If Axol is unreachable, emit a neutral pass-through so CC's normal
# flow takes over rather than hanging.
set -eo pipefail

payload=$(cat)

resp=$(/usr/bin/curl -sS --max-time 300 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Claude-PID: $PPID" \
    --data-binary "$payload" \
    http://127.0.0.1:47329/permission 2>/dev/null) || {
    # No-op response — let CC fall through to its built-in prompt.
    echo '{}'
    exit 0
}

printf '%s\n' "$resp"

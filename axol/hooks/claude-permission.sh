#!/usr/bin/env bash
# Claude Code PreToolUse hook → Axol permission bubble bridge.
#
# Fires for every matched tool call (matcher lives in ~/.claude/settings.json).
# Reads the PreToolUse JSON on stdin, POSTs it to Axol, and forwards Axol's
# JSON response verbatim — Axol decides whether to auto-allow (from cached
# rule eval) or bubble for the user.
#
# If Axol is unreachable, emit an empty decision so CC falls back to its
# built-in permission flow rather than hanging.
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

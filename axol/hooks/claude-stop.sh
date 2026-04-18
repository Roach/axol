#!/usr/bin/env bash
#
# Claude Code Stop-hook enricher. Reads the raw hook payload from stdin,
# figures out a short "what just happened" note from the repo state at
# `cwd`, splices it into the payload as `note`, and forwards to Axol's
# loopback receiver. Axol's `claude-code` adapter templates that field
# with a `| default 'finished'` fallback.
#
# Format of the note:
#   - "<branch> · <N> files changed"  (dirty repo)
#   - "<branch> · <last commit subject>" (clean repo)
#   - "<branch>"                       (clean, no commits yet)
#   - "finished"                       (not a repo, or detection failed)
#
# Safe on non-git cwd, missing jq, or Axol offline — never fails the hook.

set -u

body=$(cat)

note=''
if command -v jq >/dev/null 2>&1; then
    cwd=$(printf '%s' "$body" | jq -r '.cwd // empty' 2>/dev/null || true)
    if [ -n "$cwd" ] && [ -d "$cwd/.git" ]; then
        branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        if [ -n "$branch" ]; then
            changed=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            if [ "$changed" -gt 0 ] 2>/dev/null; then
                noun='file'
                [ "$changed" -gt 1 ] && noun='files'
                note="$branch · $changed $noun changed"
            else
                last=$(git -C "$cwd" log -1 --pretty=%s 2>/dev/null | cut -c 1-60)
                if [ -n "$last" ]; then
                    note="$branch · $last"
                else
                    note="$branch"
                fi
            fi
        fi
    fi

    # Splice the note in if we built one.
    if [ -n "$note" ]; then
        body=$(printf '%s' "$body" | jq -c --arg note "$note" '. + {note: $note}' 2>/dev/null || printf '%s' "$body")
    fi
fi

printf '%s' "$body" | curl -sS --max-time 1 -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Claude-PID: ${PPID:-0}" \
    --data-binary @- \
    http://127.0.0.1:47329/event >/dev/null 2>&1 || true

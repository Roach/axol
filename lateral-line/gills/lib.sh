# shellcheck shell=bash
# Shared helpers for lateral-line gills. Sourced — not executed directly.
#
# A gill is a short bash script that periodically queries a third-party API
# and POSTs each new item it finds straight into Axol's loopback receiver
# (http://127.0.0.1:47329/). Nothing here talks to the neuromast — gills
# are purely local and intended for pull-style integrations where the
# upstream can't webhook out to you (e.g. GitHub personal-access-token
# notifications).
#
# Named for axolotls' signature feature: the three pairs of feathery
# external gills that wave rhythmically to sample the water around them.
# Same rhythmic-sampling motion a polling loop makes.
#
# Conventions this lib enforces so each gill stays ~30 lines:
#   - Secrets come from macOS Keychain (not env vars or files).
#   - Cursor state lives under $AXOL_STATE_DIR/gills/<name>.cursor.
#   - A file lock prevents overlapping samples if launchd fires twice.
#   - Each sample probes the local Axol receiver once before calling the API
#     and exits quietly when Axol isn't up, so the gill doesn't burn
#     rate-limit budget while she's closed.

set -euo pipefail

STATE_DIR="${AXOL_STATE_DIR:-$HOME/Library/Application Support/Axol}"
LOCAL_URL="${AXOL_LOCAL_URL:-http://127.0.0.1:47329/}"
GILL_STATE_DIR="$STATE_DIR/gills"
mkdir -p "$GILL_STATE_DIR"

# gill_init NAME — claim the per-gill lock and exit silently if another
# sample is already running. Call this first from every gill.
gill_init() {
    local name="$1"
    GILL_NAME="$name"
    GILL_CURSOR_FILE="$GILL_STATE_DIR/$name.cursor"
    local lock="$GILL_STATE_DIR/$name.lock"

    exec 9>"$lock"
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || exit 0
    else
        # macOS ships without flock(1). Fall back to noclobber symlink
        # locking with a 10-minute stale window (same as lateral-line.sh).
        if ! (set -C; : >"$lock.pid") 2>/dev/null; then
            if [[ -n "$(find "$lock.pid" -mmin +10 2>/dev/null)" ]]; then
                rm -f "$lock.pid"
                (set -C; : >"$lock.pid") 2>/dev/null || exit 0
            else
                exit 0
            fi
        fi
        trap 'rm -f "$lock.pid"' EXIT
    fi
}

# gill_keychain_secret SERVICE — read a generic-password item from macOS
# Keychain by service label. Prints the password on stdout; returns 1
# (and logs) when not found, so missing credentials don't trip `set -e`.
gill_keychain_secret() {
    local service="$1"
    if ! out=$(security find-generic-password -a "$USER" -s "$service" -w 2>/dev/null); then
        gill_log "keychain item '$service' not found — skipping sample"
        return 1
    fi
    printf '%s' "$out"
}

# gill_axol_up — return 0 if Axol is listening on LOCAL_URL, 1 otherwise.
# TCP-level probe (matches lateral-line.sh): avoids burning API quota when
# Axol is closed.
gill_axol_up() {
    local host port
    host=$(printf '%s' "$LOCAL_URL" | sed -E 's|^https?://||' | cut -d/ -f1 | cut -d: -f1)
    port=$(printf '%s' "$LOCAL_URL" | sed -E 's|^https?://||' | cut -d/ -f1 | awk -F: '{print ($2=="" ? "47329" : $2)}')
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
        exec 3>&- 3<&- 2>/dev/null || true
        return 0
    fi
    return 1
}

# gill_post_envelope JSON — POST a pre-rendered Axol envelope to the
# loopback receiver. Returns the curl exit code. Envelopes matching the
# generic adapter (anything with a `title`) render without a per-source
# adapter on the Axol side.
gill_post_envelope() {
    local payload="$1"
    curl -fsS --max-time 5 -o /dev/null \
        -X POST -H 'Content-Type: application/json' \
        --data "$payload" "$LOCAL_URL"
}

# gill_cursor_read — print the saved cursor, or empty on first run.
gill_cursor_read() {
    cat "$GILL_CURSOR_FILE" 2>/dev/null || printf ''
}

# gill_cursor_write VALUE — atomic write, so a crash mid-sample can't
# truncate the cursor to a partial string.
gill_cursor_write() {
    printf '%s' "$1" >"$GILL_CURSOR_FILE.tmp"
    mv "$GILL_CURSOR_FILE.tmp" "$GILL_CURSOR_FILE"
}

# gill_log MESSAGE — timestamped stdout line, consistent with lateral-line.
gill_log() {
    printf '[%s] %s: %s\n' "$(date -u +%FT%TZ)" "${GILL_NAME:-gill}" "$*"
}

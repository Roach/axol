#!/usr/bin/env bash
# Install the lateral-line launchd agent for the current user.
#
#   AXOL_CLOUD_URL=https://your-site.webflow.io \
#   AXOL_POLL_TOKEN=your-bearer-token \
#   ./install.sh
#
# Idempotent: unloads any prior copy, rewrites the plist with absolute paths
# and the supplied env vars, and reloads. Reports a first-sample log line on
# success.
#
# Flags:
#   --uninstall   launchctl bootout the job and delete the plist. Does NOT
#                 remove the cursor (~/Library/Application Support/Axol/
#                 lateral-line.cursor) or the log file — those survive, so
#                 a subsequent reinstall resumes from where the previous
#                 run left off. Remove them manually if you want a clean
#                 slate.
#   --skip-preflight   don't verify the bearer against the cloud endpoint
#                      before writing the plist. Useful for air-gapped
#                      installs or first-run against a neuromast that
#                      isn't reachable yet.

set -euo pipefail

LABEL="com.axol.lateral-line"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Axol"
LOG="$LOG_DIR/lateral-line.log"

# --- Uninstall path --------------------------------------------------------
# Handled first so the user can run it even if the required env vars aren't
# set (common case: "I want this gone"). Mirrors gills/install.sh's own
# --uninstall for one install/uninstall idiom across the project.
if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -f "$PLIST" ]]; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
            || launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        echo "removed $PLIST"
    else
        echo "nothing to remove at $PLIST"
    fi
    echo
    echo "preserved (remove manually if desired):"
    echo "  cursor:  $HOME/Library/Application Support/Axol/lateral-line.cursor"
    echo "  log:     $LOG"
    exit 0
fi

# --- Install path ----------------------------------------------------------
# Parse optional flags before we require the env vars.
SKIP_PREFLIGHT=0
for arg in "$@"; do
    case "$arg" in
        --skip-preflight) SKIP_PREFLIGHT=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

: "${AXOL_CLOUD_URL:?set AXOL_CLOUD_URL (e.g. https://axol-alerts.webflow.io)}"
: "${AXOL_POLL_TOKEN:?set AXOL_POLL_TOKEN (the bearer you put in the Webflow dashboard)}"

# Preflight: hit the cloud with the supplied bearer before writing the plist.
# Catches the three most common misconfigurations early:
#   - wrong AXOL_CLOUD_URL (DNS / 404)
#   - wrong AXOL_POLL_TOKEN (401)
#   - neuromast deployed but not yet published (WFC "Needs deployment")
# Any of these otherwise manifest as silent once-per-minute failures in the
# launchd log, which new users don't know to check.
if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
    PROBE_URL="${AXOL_CLOUD_URL%/}/app/api/pull"
    echo "preflight: $PROBE_URL"
    http_code=$(curl -sS -o /tmp/axol-install-probe.out \
                     -w '%{http_code}' --max-time 10 \
                     -H "Authorization: Bearer $AXOL_POLL_TOKEN" \
                     "$PROBE_URL" 2>/tmp/axol-install-probe.err || true)
    case "$http_code" in
        200)
            echo "  → HTTP 200 ok"
            ;;
        401|403)
            echo "  → HTTP $http_code — bearer rejected" >&2
            echo >&2
            echo "AXOL_POLL_TOKEN doesn't match POLL_TOKEN on the neuromast." >&2
            echo "Either:" >&2
            echo "  - re-export with the value from the cloud dashboard, OR" >&2
            echo "  - if you just rotated it, click 'Redeploy' in your cloud dashboard first" >&2
            echo >&2
            echo "Re-run when fixed, or use --skip-preflight to bypass." >&2
            exit 1
            ;;
        404)
            echo "  → HTTP 404 — /app/api/pull not found at $AXOL_CLOUD_URL" >&2
            echo >&2
            echo "Likely causes:" >&2
            echo "  - AXOL_CLOUD_URL points at the wrong site" >&2
            echo "  - on Webflow Cloud: site hasn't been published since the project was deployed" >&2
            echo "    (see https://roach.github.io/axol/deploy-webflow.html troubleshooting)" >&2
            echo >&2
            echo "Re-run when fixed, or use --skip-preflight to bypass." >&2
            exit 1
            ;;
        000)
            echo "  → connection failed" >&2
            cat /tmp/axol-install-probe.err >&2 2>/dev/null || true
            echo >&2
            echo "AXOL_CLOUD_URL unreachable. Check DNS + that the URL includes the scheme." >&2
            echo "Re-run when fixed, or use --skip-preflight to bypass." >&2
            exit 1
            ;;
        *)
            echo "  → HTTP $http_code (unexpected; continuing anyway)" >&2
            echo "  response body:" >&2
            sed 's/^/    /' /tmp/axol-install-probe.out >&2 2>/dev/null || true
            ;;
    esac
    rm -f /tmp/axol-install-probe.out /tmp/axol-install-probe.err
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FORWARDER="$SCRIPT_DIR/lateral-line.sh"
if [[ ! -f "$FORWARDER" ]]; then
    echo "error: $FORWARDER not found" >&2
    exit 1
fi
# Ensure the script is executable — zip extraction or re-clones can strip
# the +x bit on some systems.
chmod +x "$FORWARDER"

# jq is required by the forwarder; fail loud now rather than one-line-per-
# minute in the launchd log.
if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq not found on PATH" >&2
    echo "  install: brew install jq" >&2
    exit 1
fi

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"

# XML-escape values before interpolating into the plist body. Without this,
# a token containing `]]>`, `<`, `&`, or `"` produces a corrupt plist that
# launchctl refuses to load — or worse, silently truncates.
xmlescape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "$s"
}
ESC_LABEL=$(xmlescape "$LABEL")
ESC_FORWARDER=$(xmlescape "$FORWARDER")
ESC_CLOUD_URL=$(xmlescape "$AXOL_CLOUD_URL")
ESC_POLL_TOKEN=$(xmlescape "$AXOL_POLL_TOKEN")
ESC_LOG=$(xmlescape "$LOG")

# Unload any prior copy so the rewrite takes effect. `launchctl unload`
# returns non-zero when nothing is loaded — tolerate that.
if [[ -f "$PLIST" ]]; then
    launchctl unload "$PLIST" 2>/dev/null || true
fi

cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>$ESC_LABEL</string>
    <key>Program</key>
    <string>$ESC_FORWARDER</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>EnvironmentVariables</key>
    <dict>
      <key>AXOL_CLOUD_URL</key>
      <string>$ESC_CLOUD_URL</string>
      <key>AXOL_POLL_TOKEN</key>
      <string>$ESC_POLL_TOKEN</string>
      <key>PATH</key>
      <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$ESC_LOG</string>
    <key>StandardErrorPath</key>
    <string>$ESC_LOG</string>
    <key>ProcessType</key>
    <string>Background</string>
  </dict>
</plist>
PLIST_EOF

# The plist contains the bearer token in plaintext — restrict to owner-only
# read/write so other accounts on the same machine can't exfiltrate it.
chmod 600 "$PLIST"

launchctl load "$PLIST"
echo "loaded $LABEL"
echo "  plist:  $PLIST"
echo "  script: $FORWARDER"
echo "  log:    $LOG"
echo
echo "verify with:  launchctl list | grep lateral-line"
echo "tail log:     tail -f $LOG"
echo "uninstall:    $0 --uninstall"

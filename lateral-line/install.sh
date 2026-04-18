#!/usr/bin/env bash
# Install the lateral-line launchd agent for the current user.
#
#   AXOL_CLOUD_URL=https://your-site.webflow.io \
#   AXOL_POLL_TOKEN=your-bearer-token \
#   ./install.sh
#
# Idempotent: unloads any prior copy, rewrites the plist with absolute paths
# and the supplied env vars, and reloads. Reports a first-tick log line on
# success.

set -euo pipefail

: "${AXOL_CLOUD_URL:?set AXOL_CLOUD_URL (e.g. https://axol-alerts.webflow.io)}"
: "${AXOL_POLL_TOKEN:?set AXOL_POLL_TOKEN (the bearer you put in the Webflow dashboard)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FORWARDER="$SCRIPT_DIR/lateral-line.sh"
if [[ ! -f "$FORWARDER" ]]; then
    echo "error: $FORWARDER not found" >&2
    exit 1
fi
# Ensure the script is executable — zip extraction or re-clones can strip
# the +x bit on some systems.
chmod +x "$FORWARDER"

LABEL="com.axol.lateral-line"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Axol"
LOG="$LOG_DIR/lateral-line.log"

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
    <integer>15</integer>
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

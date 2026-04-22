#!/usr/bin/env bash
# install.sh — write + load a launchd plist for a named gill.
#
# Usage:
#   ./install.sh github-notifications         # install (or reinstall)
#   ./install.sh github-notifications --uninstall
#
# For any gill named `<name>`, this script expects `<name>.sh` to exist
# next to it and writes `~/Library/LaunchAgents/com.axol.gill.<name>.plist`
# pointing at that script. StartInterval defaults to 30 seconds to match
# lateral-line.sh's own poll cadence.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <gill-name> [--uninstall]" >&2
    exit 2
fi

NAME="$1"
ACTION="${2:-install}"

HERE="$(cd "$(dirname "$0")" && pwd)"
GILL_SCRIPT="$HERE/$NAME.sh"
LABEL="com.axol.gill.$NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Axol"

if [[ "$ACTION" == "--uninstall" ]]; then
    if [[ -f "$PLIST" ]]; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        echo "removed $PLIST"
    else
        echo "nothing to remove at $PLIST"
    fi
    exit 0
fi

if [[ ! -x "$GILL_SCRIPT" ]]; then
    if [[ -f "$GILL_SCRIPT" ]]; then
        chmod +x "$GILL_SCRIPT"
    else
        echo "gill script not found: $GILL_SCRIPT" >&2
        exit 1
    fi
fi

# Keychain precheck. Each gill declares its expected service in a header
# comment (`# GILL_KEYCHAIN: <service-name>`) so the installer can verify
# the credential is in place *before* writing a launchd plist that would
# otherwise log "keychain item not found — skipping sample" once per minute
# with no user-facing signal. Gills without the header skip the check.
KEYCHAIN_SVC=$(awk -F': *' '/^# GILL_KEYCHAIN:/ { print $2; exit }' "$GILL_SCRIPT" | tr -d '\r')
if [[ -n "$KEYCHAIN_SVC" ]]; then
    if ! security find-generic-password -a "$USER" -s "$KEYCHAIN_SVC" >/dev/null 2>&1; then
        PAT_HELP=$(awk -F': *' '/^# GILL_PAT_HELP:/ { sub(/^# GILL_PAT_HELP: */,""); print; exit }' "$GILL_SCRIPT" | tr -d '\r')
        echo "error: keychain item '$KEYCHAIN_SVC' not found" >&2
        echo >&2
        echo "This gill ($NAME) needs a credential stored in macOS Keychain before" >&2
        echo "install can proceed. Add it with:" >&2
        echo >&2
        echo "  security add-generic-password -a \"\$USER\" -s $KEYCHAIN_SVC -w <your-token>" >&2
        echo >&2
        if [[ -n "$PAT_HELP" ]]; then
            echo "Where to get the token:" >&2
            echo "  $PAT_HELP" >&2
            echo >&2
        fi
        echo "Then re-run: $0 $NAME" >&2
        exit 1
    fi
    echo "keychain: $KEYCHAIN_SVC → found"
fi

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Escape for plist XML. Paths with apostrophes or ampersands are rare on
# macOS but cheap to handle; matches lateral-line/install.sh's approach.
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
ESC_LABEL=$(printf '%s' "$LABEL" | esc)
ESC_SCRIPT=$(printf '%s' "$GILL_SCRIPT" | esc)
ESC_LOG=$(printf '%s' "$LOG_DIR/gill-$NAME.log" | esc)

cat >"$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>$ESC_LABEL</string>
    <key>Program</key>
    <string>$ESC_SCRIPT</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$ESC_LOG</string>
    <key>StandardErrorPath</key>
    <string>$ESC_LOG</string>
  </dict>
</plist>
PLIST_END

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "installed $LABEL"
echo "  script: $GILL_SCRIPT"
echo "  log:    $LOG_DIR/gill-$NAME.log"
echo
echo "tail log: tail -f $LOG_DIR/gill-$NAME.log"
echo "uninstall: $0 $NAME --uninstall"

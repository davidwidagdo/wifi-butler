#!/usr/bin/env bash
#
# Remove the auto-login LaunchAgent. Leaves scripts and config in place.
#
set -euo pipefail

LABEL="com.davidwidagdo.wifi-autologin"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null \
  || launchctl unload "$PLIST_DST" 2>/dev/null \
  || true
rm -f "$PLIST_DST"

echo "Removed LaunchAgent ${LABEL}."
echo "(Scripts and config were left in place.)"

#!/usr/bin/env bash
#
# Install the auto-login monitor as a launchd LaunchAgent (runs at login,
# restarts automatically if it exits).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.davidwidagdo.wifi-autologin"
PLIST_SRC="${SCRIPT_DIR}/${LABEL}.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
SCRIPT="${SCRIPT_DIR}/wifi-autologin.sh"
LOG="${HOME}/Library/Logs/wifi-autologin.log"

# 1. Ensure config exists and is filled in.
if [[ ! -f "${SCRIPT_DIR}/config" ]]; then
  cp "${SCRIPT_DIR}/config.example" "${SCRIPT_DIR}/config"
  chmod 600 "${SCRIPT_DIR}/config"
  echo "Created ${SCRIPT_DIR}/config from example."
  echo "Fill in USERNAME / PASSWORD / LOGIN_URL, then re-run ./install.sh."
  exit 1
fi
chmod 600 "${SCRIPT_DIR}/config"
chmod +x "${SCRIPT_DIR}"/*.sh

# 2. Generate the LaunchAgent from the template with resolved paths.
mkdir -p "${HOME}/Library/LaunchAgents"
sed -e "s|__SCRIPT__|${SCRIPT}|g" -e "s|__LOG__|${LOG}|g" "$PLIST_SRC" > "$PLIST_DST"
echo "Installed LaunchAgent -> $PLIST_DST"

# 3. (Re)load it.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
if launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null; then
  echo "Loaded via launchctl bootstrap."
else
  launchctl load "$PLIST_DST"
  echo "Loaded via launchctl load (legacy)."
fi

echo "Done. Logs: $LOG"
echo "Check status: launchctl list | grep wifi-autologin"

#!/usr/bin/env bash
#
# Store the portal password in the macOS login Keychain (best practice) instead
# of keeping it plaintext in `config`. You type it here, so it is not saved to
# shell history or written to disk by this script. (It is briefly passed to the
# `security` tool, so it can appear in this user's process list for an instant.)
#
# After storing, this blanks the PASSWORD line in `config` so the monitor reads
# the secret from the Keychain from then on.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "config not found. Copy config.example -> config and fill in USERNAME first."
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"
: "${USERNAME:?USERNAME not set in config}"
: "${KEYCHAIN_SERVICE:=wifi-autologin}"

printf 'Password for "%s" (service "%s"): ' "$USERNAME" "$KEYCHAIN_SERVICE"
read -rs PW
echo

if [[ -z "$PW" ]]; then
  echo "Empty password — aborted."
  exit 1
fi

# -U updates the item if it already exists; -T trusts the security binary so the
# background agent can read it without an interactive prompt.
security add-generic-password -U \
  -a "$USERNAME" \
  -s "$KEYCHAIN_SERVICE" \
  -T /usr/bin/security \
  -w "$PW"
unset PW

# Verify it reads back.
if security find-generic-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then
  echo "Stored and verified in Keychain (service=$KEYCHAIN_SERVICE, account=$USERNAME)."
else
  echo "WARNING: stored but could not read it back — check Keychain Access."
  exit 1
fi

# Blank PASSWORD in config so the Keychain becomes the source of truth.
if grep -qE '^PASSWORD=' "$CONFIG_FILE"; then
  sed -i '' -E 's|^PASSWORD=.*|PASSWORD=""|' "$CONFIG_FILE"
  echo "Cleared plaintext PASSWORD in $CONFIG_FILE."
fi

echo "Done. The monitor will now read the password from the Keychain."

#!/usr/bin/env bash
#
# WiFi captive-portal auto-login monitor.
# Watches connectivity and re-authenticates to the portal when logged out.
#
# Usage:
#   ./wifi-autologin.sh          run forever (used by the launchd agent)
#   ./wifi-autologin.sh --once   single check + login, then exit (for testing)
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"

# Apple's captive-portal probe returns a page containing "Success" only when
# there is real internet access; otherwise the portal intercepts the request.
# Both are overridable via the environment so the flow can be tested locally.
PROBE_URL="${PROBE_URL:-http://captive.apple.com/hotspot-detect.html}"
PROBE_MARKER="${PROBE_MARKER:-<TITLE>Success</TITLE>}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: config not found at $CONFIG_FILE (copy config.example -> config and fill it in)."
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  : "${LOGIN_URL:?LOGIN_URL not set in config}"
  : "${USERNAME:?USERNAME not set in config}"
  : "${POLL_INTERVAL:=15}"
  : "${KEYCHAIN_SERVICE:=wifi-autologin}"
  : "${PORTAL_MARKER:=}"
  # Host used for portal-presence gating; derive from LOGIN_URL when unset.
  if [[ -z "${PORTAL_HOST:-}" ]]; then
    PORTAL_HOST="${LOGIN_URL#*://}"
    PORTAL_HOST="${PORTAL_HOST%%/*}"
  fi

  # Best practice on macOS: read the password from the login Keychain rather
  # than a plaintext file. If config still holds a PASSWORD we honour it as a
  # fallback (run ./keychain-setup.sh to migrate).
  if [[ -z "${PASSWORD:-}" ]]; then
    PASSWORD="$(security find-generic-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
  fi
  : "${PASSWORD:?No password: run ./keychain-setup.sh, or set PASSWORD in config}"
}

# Returns 0 when internet is reachable, 1 when behind the portal / offline.
check_internet() {
  local body
  body="$(curl -s -m 5 "$PROBE_URL" 2>/dev/null)" || return 1
  [[ "$body" == *"$PROBE_MARKER"* ]]
}

# Returns 0 if the configured portal is actually reachable on this network (and
# matches PORTAL_MARKER when set), 1 otherwise. Keeps the script from POSTing
# credentials on no-login/offline networks or to a foreign captive portal.
portal_present() {
  [[ -z "${PORTAL_HOST:-}" ]] && return 1
  local body
  body="$(curl -s -m 4 "http://${PORTAL_HOST}/" 2>/dev/null)" || return 1
  [[ -z "${PORTAL_MARKER:-}" ]] && return 0
  local matched=1
  shopt -s nocasematch
  [[ "$body" == *"$PORTAL_MARKER"* ]] && matched=0
  shopt -u nocasematch
  return $matched
}

do_login() {
  local args=(--data-urlencode "username=${USERNAME}" --data-urlencode "password=${PASSWORD}")
  local field
  for field in "${EXTRA_FIELDS[@]:-}"; do
    [[ -n "$field" ]] && args+=(--data-urlencode "$field")
  done
  curl -s -m 15 "${args[@]}" "$LOGIN_URL" -o /dev/null
}

attempt() {
  if check_internet; then
    log "Connected - skipping."
    return 0
  fi
  if ! portal_present; then
    log "No internet and portal not present - skipping (this network doesn't use it)."
    return 0
  fi
  log "Captive portal detected - logging in to ${LOGIN_URL}"
  do_login
  sleep 3
  if check_internet; then
    log "Login OK."
  else
    log "Login FAILED - check credentials / LOGIN_URL / EXTRA_FIELDS."
  fi
}

main() {
  load_config
  if [[ "${1:-}" == "--once" ]]; then
    attempt
    exit 0
  fi
  log "Monitor started (probe every ${POLL_INTERVAL}s)."
  while true; do
    attempt
    sleep "$POLL_INTERVAL"
  done
}

main "$@"

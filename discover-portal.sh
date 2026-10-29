#!/usr/bin/env bash
#
# One-time helper: inspect the captive portal's login form so you can fill in
# LOGIN_URL and EXTRA_FIELDS in `config`.
#
# Run it while connected to the WiFi but logged OUT of the portal.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"
HOST=""
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  HOST="${PORTAL_HOST:-}"
fi

PROBE_URL="http://captive.apple.com/hotspot-detect.html"
OUT="${SCRIPT_DIR}/portal.html"

echo "== 1. Following captive-portal redirect from the probe =="
redirect="$(curl -s -o /dev/null -w '%{redirect_url}' "$PROBE_URL")"
if [[ -n "$redirect" ]]; then
  echo "Portal redirects you to: $redirect"
  if [[ -z "$HOST" ]]; then
    HOST="${redirect#*://}"
    HOST="${HOST%%/*}"
  fi
else
  echo "No redirect seen - you may already be logged in, or the portal uses JS/meta refresh."
fi

if [[ -z "$HOST" ]]; then
  echo "Set PORTAL_HOST in $CONFIG_FILE to the portal's address and run again."
  exit 1
fi

echo
echo "== 2. Downloading portal page http://${HOST}/ =="
if curl -sL -m 8 "http://${HOST}/" -o "$OUT" && [[ -s "$OUT" ]]; then
  echo "Saved to $OUT"
else
  echo "WARNING: could not download http://${HOST}/ - the portal may be"
  echo "         unreachable or you may not be on this network. The analysis"
  echo "         below will be empty or stale."
fi

echo
echo "== 3. Form actions found =="
grep -oiE '<form[^>]*action="[^"]*"[^>]*>' "$OUT" || echo "(none - open $OUT manually)"

echo
echo "== 4. Input / hidden fields found =="
grep -oiE '<input[^>]*name="[^"]*"[^>]*>' "$OUT" || echo "(none found)"

echo
if grep -qiE 'name="(challenge|chap-id|chap-challenge)"' "$OUT"; then
  echo "!! This looks like a MikroTik CHAP (MD5 challenge) portal."
  echo "   The password must be hashed as md5(chap-id + password + challenge)."
  echo "   Report this so do_login() can be extended for CHAP."
else
  echo "Looks like a plain POST login (username/password sent directly)."
fi

echo
echo "Next: set LOGIN_URL (the form action, as an absolute URL) and any hidden"
echo "fields as EXTRA_FIELDS in $CONFIG_FILE, then run:"
echo "  ./wifi-autologin.sh --once"

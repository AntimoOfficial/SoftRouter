#!/bin/bash
# Exercise the fresh-install guard without touching system paths or launchd.
set -eu
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/softrouter-install-test.XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT
INSTALL=$TMP/new-install
PLIST=$TMP/new.plist
STATE=$TMP/new-state
LABEL=org.softrouter.gateway
LOADED=
passed=0
fail() { printf 'Rejected: %s\n' "$*" >&2; exit 1; }
mock_launchctl() {
  [ "$#" = 2 ] && [ "$1" = print ] || exit 2
  [ "$2" = "system/$LOADED" ]
}
# Extract only the guard; never evaluate the installer entry point.
/usr/bin/awk '
  $0 == "check_existing_deployment() {" {copy=1}
  copy {print}
  copy && $0 == "}" {done=1; exit}
  END {if(!done) exit 1}
' "$BASE/install.sh" | /usr/bin/sed \
  -e 's|/Library/AirGateway|"$TMP/old-install"|g' \
  -e 's|/Library/LaunchDaemons/org.airgateway.gateway.plist|"$TMP/old.plist"|g' \
  -e 's|/private/var/run/air-gateway|"$TMP/old-state"|g' \
  -e 's|/bin/launchctl|mock_launchctl|g' > "$TMP/guard.sh"
. "$TMP/guard.sh"
accept() {
  (check_existing_deployment) || { printf 'Unexpected rejection\n' >&2; exit 1; }
  passed=$((passed+1))
}
reject() {
  if (check_existing_deployment) > "$TMP/rejection" 2>&1; then
    printf 'Existing deployment was not rejected\n' >&2; exit 1
  fi
  passed=$((passed+1))
}
accept
for p in "$INSTALL" "$PLIST" "$STATE" "$TMP/old-install" "$TMP/old.plist" "$TMP/old-state"; do
  : > "$p"
  reject
  [ -f "$p" ] || { printf 'Guard modified an existing path\n' >&2; exit 1; }
  rm "$p"
  ln -s "$TMP/missing" "$p"
  reject
  [ -L "$p" ] || { printf 'Guard modified a symlink\n' >&2; exit 1; }
  rm "$p"
done
for LOADED in "$LABEL" org.airgateway.gateway; do reject; done
LOADED=org.example.unrelated
accept
printf 'Installation guard: %s passed with temporary paths and a launchd double.\n' "$passed"

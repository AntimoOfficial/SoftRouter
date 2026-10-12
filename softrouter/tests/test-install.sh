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
# launchd must not keep persistent fds into files owned by the rotating daemon.
python3 - "$BASE/org.softrouter.gateway.plist" <<'PY'
import pathlib, plistlib, sys
plist = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
assert plist['StandardOutPath'] == '/dev/null'
assert plist['StandardErrorPath'] == '/dev/null'
assert plist['ProgramArguments'][2] == '--service'
assert plist['KeepAlive'] is True
PY
passed=$((passed+4))
mock_install_stat() {
  local metadata
  metadata=$(/usr/bin/stat "$@") || return 1
  printf '%s:%s\n' "${LOG_OWNER:-0}" "${metadata#*:}"
}
for name in regular_root_file check_existing_logs; do
  /usr/bin/awk -v name="$name" '
    $0 == name "() {" {copy=1}
    copy {print}
    copy && $0 == "}" {done=1; exit}
    END {if(!done) exit 1}
  ' "$BASE/install.sh" | /usr/bin/sed 's|/usr/bin/stat|mock_install_stat|g' > "$TMP/log-guard.sh"
  . "$TMP/log-guard.sh"
done
LOGS="$TMP/logs"
log_accept() { (check_existing_logs) || { printf 'Unexpected log rejection\n' >&2; exit 1; }; passed=$((passed+1)); }
log_reject() {
  if (check_existing_logs) > "$TMP/log-rejection" 2>&1; then printf 'Untrusted logs accepted\n' >&2; exit 1; fi
  passed=$((passed+1))
}
log_accept
mkdir "$LOGS"; chmod 755 "$LOGS"
log_accept
for name in gateway.log error.log guardian.log guardian-error.log; do
  for suffix in .1 .2 .3; do
    printf 'retained evidence\n' > "$LOGS/$name$suffix"
    chmod 600 "$LOGS/$name$suffix"
    log_reject
    [ "$(cat "$LOGS/$name$suffix")" = 'retained evidence' ] || exit 1
    rm "$LOGS/$name$suffix"
  done
done
printf 'retained target\n' > "$LOGS/target"; chmod 644 "$LOGS/target"
ln -s "$LOGS/target" "$LOGS/guardian-error.log.3"
log_reject
[ -L "$LOGS/guardian-error.log.3" ] && [ "$(cat "$LOGS/target")" = 'retained target' ]
rm "$LOGS/guardian-error.log.3"
ln "$LOGS/target" "$LOGS/gateway.log.1"
log_reject
[ -f "$LOGS/gateway.log.1" ] && [ "$(cat "$LOGS/target")" = 'retained target' ]
rm "$LOGS/gateway.log.1"
LOG_OWNER=1; log_reject; LOG_OWNER=0
for name in gateway.log error.log guardian.log guardian-error.log; do
  for suffix in '' .1 .2 .3; do printf 'trusted history\n' > "$LOGS/$name$suffix"; chmod 644 "$LOGS/$name$suffix"; done
done
printf 'trusted status\n' > "$LOGS/status.txt"; chmod 644 "$LOGS/status.txt"
log_accept
printf 'Installation guard: %s passed with temporary paths and a launchd double.\n' "$passed"

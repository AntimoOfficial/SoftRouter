#!/bin/bash
# Fresh installation only. Configuration is parsed as data, never sourced.
set -eu
set -o pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
SOURCE=$(cd -P "$(/usr/bin/dirname "$0")" && /bin/pwd)
INSTALL=/Library/SoftRouter
LOGS=/Library/Logs/SoftRouter
STATE=/private/var/run/softrouter
LABEL=org.softrouter.gateway
PLIST=/Library/LaunchDaemons/org.softrouter.gateway.plist
STAGE=
INSTALL_CREATED=0
PLIST_CREATED=0
ENABLED=0
SUCCESS=0
fail() { printf 'SoftRouter installation: %s\n' "$*" >&2; exit 1; }
regular_root_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f '%u:%Lp:%l' "$1")" = "0:$2:1" ]
}
check_payload() {
  local base=$1 p
  for p in gateway.sh gatewayctl config.sh org.softrouter.gateway.plist diagnose.sh diagnostics/lib.sh diagnostics/render.awk; do
    [ -f "$base/$p" ] && [ ! -L "$base/$p" ] || fail "Missing or symbolic-link payload: $p"
  done
  /bin/bash -n "$base/gateway.sh"
  /bin/bash -n "$base/gatewayctl"
  /bin/bash -n "$base/config.sh"
  /bin/bash -n "$base/diagnose.sh"
  /bin/bash -n "$base/diagnostics/lib.sh"
  /usr/bin/plutil -lint "$base/org.softrouter.gateway.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$base/org.softrouter.gateway.plist")" = "$LABEL" ] || fail 'Wrong launchd label.'
  [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$base/org.softrouter.gateway.plist")" = /bin/bash ] || fail 'Wrong interpreter.'
  [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$base/org.softrouter.gateway.plist")" = "$INSTALL/gateway.sh" ] || fail 'Wrong installed daemon path.'
  [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$base/org.softrouter.gateway.plist")" = --service ] || fail 'Wrong service entry point.'
  [ "$(/usr/libexec/PlistBuddy -c 'Print :StandardOutPath' "$base/org.softrouter.gateway.plist")" = "$LOGS/gateway.log" ] || fail 'Wrong log path.'
  [ "$(/usr/libexec/PlistBuddy -c 'Print :StandardErrorPath' "$base/org.softrouter.gateway.plist")" = "$LOGS/error.log" ] || fail 'Wrong error log path.'
}
# Renaming must not bypass the fresh-install boundary of the previous release.
check_existing_deployment() {
  local p label
  for p in "$INSTALL" "$PLIST" "$STATE" /Library/AirGateway \
    /Library/LaunchDaemons/org.airgateway.gateway.plist /private/var/run/air-gateway; do
    [ ! -e "$p" ] && [ ! -L "$p" ] || fail "Existing deployment or recovery state will not be overwritten: $p"
  done
  for label in "$LABEL" org.airgateway.gateway; do
    if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
      fail "Existing gateway launchd job is loaded: $label"
    fi
  done
}
usage() { printf 'Usage: /bin/bash install.sh --check\n       sudo /bin/bash install.sh --config /absolute/path/gateway.conf\n'; }
if [ "${1-}" = --check ]; then
  [ "$#" = 1 ] || fail 'Unexpected arguments.'
  check_payload "$SOURCE"
  printf 'Payload syntax and launchd template verified. No installation or network operation performed.\n'
  exit 0
fi
[ "$#" = 2 ] && [ "$1" = --config ] || { usage >&2; exit 1; }
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'This installer requires macOS.'
[ "$(/usr/bin/id -u)" = 0 ] || fail 'Run installation with sudo in your local terminal.'
CONFIG_SOURCE=$2
case "$CONFIG_SOURCE" in /*) ;; *) fail 'Use an absolute configuration path.' ;; esac
[ -f "$CONFIG_SOURCE" ] && [ ! -L "$CONFIG_SOURCE" ] || fail 'Configuration must be a regular, non-symlink file.'
check_existing_deployment
for p in /Library /Library/LaunchDaemons /Library/Logs /private/var/run; do
  [ -d "$p" ] && [ ! -L "$p" ] && [ "$(/usr/bin/stat -f %u "$p")" = 0 ] || fail "Unexpected parent directory: $p"
done
if [ -e "$LOGS" ] || [ -L "$LOGS" ]; then
  [ -d "$LOGS" ] && [ ! -L "$LOGS" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$LOGS")" = 0:755 ] || fail 'Existing log directory is not trusted.'
  for p in gateway.log error.log status.txt; do
    if [ -e "$LOGS/$p" ] || [ -L "$LOGS/$p" ]; then regular_root_file "$LOGS/$p" 644 || fail "Untrusted existing log: $p"; fi
  done
fi
STAGE=$(/usr/bin/mktemp -d /private/tmp/softrouter-install.XXXXXXXX)
/bin/chmod 700 "$STAGE"
cleanup_install() {
  local result=$? safe_remove=1 n archive
  trap - EXIT HUP INT TERM
  set +e
  if [ "$SUCCESS" = 0 ]; then
    if [ "$ENABLED" = 1 ]; then
      /bin/launchctl disable "system/$LABEL" || safe_remove=0
      /bin/launchctl print "system/$LABEL" > "$STAGE/launchd-failure.txt" 2>&1
      if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then /bin/launchctl bootout "system/$LABEL" || safe_remove=0; fi
      for n in {1..35}; do
        [ -e "$STATE" ] || [ -L "$STATE" ] || break
        /bin/sleep 1
      done
    fi
    if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then safe_remove=0; fi
    if [ -e "$STATE" ] || [ -L "$STATE" ]; then safe_remove=0; fi
    if [ "$safe_remove" = 1 ]; then
      [ "$PLIST_CREATED" = 0 ] || /bin/rm -f "$PLIST"
      if [ "$INSTALL_CREATED" = 1 ]; then
        /bin/rm -f "$INSTALL/gateway.sh" "$INSTALL/gatewayctl" "$INSTALL/config.sh" "$INSTALL/gateway.conf" "$INSTALL/diagnose.sh" "$INSTALL/diagnostics/lib.sh" "$INSTALL/diagnostics/render.awk"
        /bin/rmdir "$INSTALL/diagnostics" 2>/dev/null || :
        /bin/rmdir "$INSTALL" || printf 'Installation directory contains other files and was retained.\n' >&2
      fi
    else
      printf 'Job or recovery state remains. Installed files were retained; no PF or interface resources were forcibly removed.\n' >&2
    fi
    # Preserve the frozen payload/configuration and diagnostics for inspection.
    if [ -d "$LOGS" ] && [ ! -L "$LOGS" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$LOGS")" = 0:755 ]; then
      archive=$(/usr/bin/mktemp -d "$LOGS/install-failure.XXXXXXXX")
      if [ -n "$archive" ] && /bin/mv "$STAGE" "$archive/payload"; then STAGE="$archive/payload"; fi
    fi
    printf 'Root-private installation diagnostics: %s\n' "$STAGE" >&2
  else
    /bin/rm -f "$STAGE/gateway.sh" "$STAGE/gatewayctl" "$STAGE/config.sh" "$STAGE/gateway.conf" "$STAGE/org.softrouter.gateway.plist" "$STAGE/preflight.log" "$STAGE/pf-before.txt" "$STAGE/prior-status.txt" "$STAGE/diagnose.sh" "$STAGE/diagnostics/lib.sh" "$STAGE/diagnostics/render.awk"
    /bin/rmdir "$STAGE/diagnostics"
    /bin/rmdir "$STAGE" || printf 'Private staging directory retained: %s\n' "$STAGE"
  fi
  exit "$result"
}
trap cleanup_install EXIT
trap 'exit 130' HUP INT TERM
/bin/mkdir "$STAGE/diagnostics"
# Freeze all executable inputs before checking or evaluating the config library.
for p in gateway.sh gatewayctl config.sh org.softrouter.gateway.plist diagnose.sh diagnostics/lib.sh diagnostics/render.awk; do
  [ -f "$SOURCE/$p" ] && [ ! -L "$SOURCE/$p" ] || fail "Invalid source payload: $p"
  /usr/bin/install -o root -g wheel -m 500 "$SOURCE/$p" "$STAGE/$p"
done
/usr/bin/install -o root -g wheel -m 600 "$CONFIG_SOURCE" "$STAGE/gateway.conf"
check_payload "$STAGE"
regular_root_file "$STAGE/config.sh" 500 && regular_root_file "$STAGE/gateway.conf" 600 || fail 'Frozen configuration ownership is invalid.'
# This is trusted, root-private program code; gateway.conf itself is never sourced.
. "$STAGE/config.sh"
load_config "$STAGE/gateway.conf" || fail 'Configuration validation failed.'
[ "$(/usr/sbin/sysctl -n net.inet.ip.forwarding)" = 0 ] || fail 'IPv4 forwarding is already enabled. An existing gateway is left untouched.'
/sbin/pfctl -s info > "$STAGE/pf-before.txt" 2>&1 || fail 'Cannot inspect PF ownership.'
/usr/bin/grep -Eq '^Status: Disabled([[:space:]]|$)' "$STAGE/pf-before.txt" || fail 'PF is already enabled or its status is unknown. Existing network services are left untouched.'
# Claim the new install directory atomically; never merge into an existing one.
/bin/mkdir -m 755 "$INSTALL"
INSTALL_CREATED=1
/usr/bin/install -d -o root -g wheel -m 755 "$LOGS"
/usr/bin/install -o root -g wheel -m 500 "$STAGE/gateway.sh" "$INSTALL/gateway.sh"
/usr/bin/install -o root -g wheel -m 755 "$STAGE/gatewayctl" "$INSTALL/gatewayctl"
/usr/bin/install -d -o root -g wheel -m 755 "$INSTALL/diagnostics"
for p in diagnose.sh diagnostics/lib.sh diagnostics/render.awk; do
  /usr/bin/install -o root -g wheel -m 644 "$STAGE/$p" "$INSTALL/$p"
done
/usr/bin/install -o root -g wheel -m 500 "$STAGE/config.sh" "$INSTALL/config.sh"
/usr/bin/install -o root -g wheel -m 600 "$STAGE/gateway.conf" "$INSTALL/gateway.conf"
[ ! -e "$PLIST" ] && [ ! -L "$PLIST" ] || fail 'Launchd plist appeared concurrently; it was not overwritten.'
PLIST_CREATED=1
/usr/bin/install -o root -g wheel -m 644 "$STAGE/org.softrouter.gateway.plist" "$PLIST"
for p in gateway.log error.log; do
  if [ ! -e "$LOGS/$p" ]; then /usr/bin/install -o root -g wheel -m 644 /dev/null "$LOGS/$p"; fi
done
if /bin/bash "$INSTALL/gateway.sh" --preflight > "$STAGE/preflight.log" 2>&1; then
  /bin/cat "$STAGE/preflight.log"
else
  /bin/cat "$STAGE/preflight.log" >&2
  fail 'Daemon preflight failed; no launchd service was started.'
fi
# Do not mistake a previous installation's status for this daemon's readiness.
if [ -f "$LOGS/status.txt" ]; then /bin/cp "$LOGS/status.txt" "$STAGE/prior-status.txt"; fi
/bin/rm -f "$LOGS/status.txt"
ENABLED=1
/bin/launchctl enable "system/$LABEL"
/bin/launchctl bootstrap system "$PLIST"
running=0
for n in {1..45}; do
  if regular_root_file "$LOGS/status.txt" 644 &&
     /usr/bin/grep -q '^state=RUNNING$' "$LOGS/status.txt" &&
     /usr/bin/grep -q '^forwarding=1$' "$LOGS/status.txt" &&
     /bin/launchctl print "system/$LABEL" 2>/dev/null | /usr/bin/awk '$1=="state" && $2=="=" && $3=="running"{found=1} END{exit !found}'; then
    running=1; break
  fi
  /bin/sleep 1
done
[ "$running" = 1 ] || fail 'Daemon did not reach RUNNING; this installation will be stopped and diagnosed.'
SUCCESS=1
printf 'SoftRouter installed and RUNNING.\n'
/bin/cat "$LOGS/status.txt"
printf 'Status: %s/gatewayctl status\nStop: sudo %s/gatewayctl stop\nUninstall: sudo %s/gatewayctl uninstall\n' "$INSTALL" "$INSTALL" "$INSTALL"

#!/bin/bash
# Exercise selected production functions with every network command replaced.
# Never source the daemon entry point or contact live networking.
set -eu
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/softrouter-daemon-test.XXXXXXXX")
# macOS TMPDIR may begin with the /var symlink; model a physical log directory.
TMP=$(cd -P "$TMP" && /bin/pwd)
trap 'rm -rf "$TMP"' EXIT
ROOT_DIR=$TMP/state
mkdir "$ROOT_DIR"
UPSTREAM_INTERFACE=en2
DOWNSTREAM_INTERFACE=en9
GATEWAY_ADDRESS=192.168.50.1
CLIENT_ADDRESS=192.168.50.2
TAG=softrouter
ANCHOR=com.apple/softrouter
passed=0
fail() { printf 'Test failed: %s\n' "$*" >&2; exit 1; }
ok() { "$@" || fail "$*"; passed=$((passed+1)); }
bad() { if ("$@") > "$TMP/expected-failure" 2>&1; then fail "Expected rejection: $*"; fi; passed=$((passed+1)); }
log() { :; }
intent() { : > "$ROOT_DIR/$1-intent"; }
load_function() {
  /usr/bin/awk -v name="$1" '
    $0 == name "() {" {copy=1}
    copy {print}
    copy && $0 == "}" {done=1; exit}
    END {if(!done) exit 1}
  ' "$BASE/gateway.sh" | /usr/bin/sed \
    -e 's|/sbin/pfctl|mock_pfctl|g' \
    -e 's|/sbin/ifconfig|mock_ifconfig|g' \
    -e 's|/usr/sbin/ndp|mock_ndp|g' \
    -e 's|/usr/sbin/networksetup|mock_networksetup|g' \
    -e 's|/usr/sbin/ipconfig|mock_ipconfig|g' \
    -e 's|/sbin/route|mock_route|g' \
    -e 's|/usr/bin/stat|mock_log_stat|g' \
    -e 's|/usr/bin/id -u|mock_log_uid|g' > "$TMP/function.sh"
  . "$TMP/function.sh"
}
for name in write_rules ipv6_interface_mode prepare_ipv6 ipv6_runtime_ok restore_ipv6 empty_children default_hooks ref_tokens upstream_observe; do
  load_function "$name"
done
mock_pfctl() {
  [ "$#" = 5 ] && [ "$1" = -n ] && [ "$2" = -a ] && [ "$3" = "$ANCHOR" ] && [ "$4" = -f ] || fail 'Unexpected PF command'
  [ -s "$5" ] || fail 'Empty rules'
  printf '%s\n' "$5" >> "$TMP/parse-calls"
}
printf 'lo0: flags=0\nen2: flags=0\nen9: flags=0\n' > "$ROOT_DIR/interfaces-before"
write_rules
ok test "$(wc -l < "$TMP/parse-calls" | tr -d ' ')" = 2
for rules in "$ROOT_DIR/rules" "$ROOT_DIR/protection-rules"; do
  ok grep -Fxq 'pass in quick on en2 inet proto udp from any port 67 to any port 68 tag softrouter_dhcp no state label "gateway_dhcp_in"' "$rules"
  ok grep -Fxq 'block drop out quick inet tagged softrouter_dhcp label "gateway_dhcp_no_transit"' "$rules"
  ok awk '/gateway_dhcp_in/ {dhcp=NR} /gateway_other_transit/ {block=NR} END {exit !(dhcp>0 && dhcp<block)}' "$rules"
done
ok grep -Fxq 'nat on en2 inet from 192.168.50.2 to any -> (en2)' "$ROOT_DIR/rules"
ok grep -Fq 'keep state (if-bound)' "$ROOT_DIR/rules"
ok grep -Fq 'block drop out quick inet tagged softrouter label "gateway_other_egress"' "$ROOT_DIR/rules"
ok awk '/gateway_ingress/ {ingress=NR} /gateway_dhcp_in/ {dhcp=NR} END {exit !(ingress>0 && ingress<dhcp)}' "$ROOT_DIR/rules"
bad grep -Eq 'route-to|reply-to|nat on' "$ROOT_DIR/protection-rules"
UPSTREAM_INTERFACE='en2;invalid'
bad write_rules
UPSTREAM_INTERFACE=en2

# IPv6 state machine: unavailable, zero flags, real disable and lying ioctl.
MODE=absent
LIE=0
mock_ndp() {
  [ "$1 $2" = '-i en9' ] || return 1
  case "$MODE" in absent) printf 'ioctl (SIOCGIFINFO_IN6): Invalid argument\n' >&2; return 1 ;; unknown) return 1 ;; *) return 0 ;; esac
}
snapshot() {
  printf 'en9: flags=0\n' > "$ROOT_DIR/interface"
  case "$MODE" in
    enabled) printf '\tnd6 options=201<PERFORMNUD,DAD>\n' >> "$ROOT_DIR/interface" ;;
    disabled) printf '\tnd6 options=29<PERFORMNUD,IFDISABLED,AUTO_LINKLOCAL>\n' >> "$ROOT_DIR/interface" ;;
    addressed) printf '\tinet6 fe80::1 prefixlen 64\n' >> "$ROOT_DIR/interface" ;;
  esac
}
mock_ifconfig() {
  [ "$1" = en9 ] || return 1
  if [ "$#" = 1 ]; then snapshot; cat "$ROOT_DIR/interface"; return; fi
  printf '%s\n' "$*" >> "$TMP/interface-writes"
  [ "$LIE" = 0 ] || return 0
  case "$2 $3" in 'inet6 ifdisabled') MODE=disabled ;; 'inet6 -ifdisabled') MODE=enabled ;; *) return 1 ;; esac
}
snapshot
ok test "$(ipv6_interface_mode "$ROOT_DIR/interface")" = absent
printf 'absent\n' > "$ROOT_DIR/ipv6-baseline"
ok prepare_ipv6
ok test ! -e "$TMP/interface-writes"
ok restore_ipv6
ok test ! -e "$TMP/interface-writes"
MODE=zero; snapshot
ok test "$(ipv6_interface_mode "$ROOT_DIR/interface")" = enabled
MODE=unknown; snapshot
bad ipv6_interface_mode "$ROOT_DIR/interface"
MODE=addressed; snapshot
bad ipv6_interface_mode "$ROOT_DIR/interface"
MODE=enabled; printf 'enabled\n' > "$ROOT_DIR/ipv6-baseline"
ok prepare_ipv6
ok test "$MODE" = disabled
snapshot
ok ipv6_runtime_ok "$ROOT_DIR/interface"
# Simulate interruption after ioctl but before the completion marker.
rm "$ROOT_DIR/v6-changed"
ok restore_ipv6
ok test "$MODE" = enabled
LIE=1
bad prepare_ipv6
LIE=0; MODE=absent; snapshot
bad ipv6_runtime_ok "$ROOT_DIR/interface"

# PF parent calls are allowed only when each permitted child is empty.
PARENT_EXTRA=0
CHILD_EXTRA=0
UNKNOWN_CHILD=0
pf() {
  case "$*" in
    '-s Anchors') printf 'com.apple\n' ;;
    '-a com.apple -s Anchors')
      printf '200.AirDrop\n250.ApplicationFirewall\nsoftrouter\n'
      if [ "$UNKNOWN_CHILD" = 1 ]; then printf 'unexpected\n'; fi ;;
    '-a com.apple -sr')
      printf 'anchor "200.AirDrop/*" all\nanchor "250.ApplicationFirewall/*" all\n'
      if [ "$PARENT_EXTRA" = 1 ]; then printf 'pass all\n'; fi ;;
    '-a com.apple -sn') : ;;
    '-a com.apple/200.AirDrop -s rules') if [ "$CHILD_EXTRA" = 1 ]; then printf 'pass all\n'; fi ;;
    '-a com.apple/'*' -s rules'|'-a com.apple/'*' -s nat'|'-a com.apple/'*' -s Anchors') : ;;
    '-sn') printf 'nat-anchor "com.apple/*" all\nrdr-anchor "com.apple/*" all\n' ;;
    '-sr') printf 'scrub-anchor "com.apple/*" all fragment reassemble\nanchor "com.apple/*" all\n' ;;
    *) fail "Unexpected mock query: $*" ;;
  esac
}
ok default_hooks
ok empty_children
PARENT_EXTRA=1; bad empty_children; PARENT_EXTRA=0
CHILD_EXTRA=1; bad empty_children; CHILD_EXTRA=0
UNKNOWN_CHILD=1; bad empty_children; UNKNOWN_CHILD=0
printf 'TOKENS:\n42 pfctl 1234 0 days 00:00:01\n' > "$TMP/refs"
ok test "$(ref_tokens "$TMP/refs")" = 1234
printf 'unrecognized reference format\n' > "$TMP/refs"
bad ref_tokens "$TMP/refs"

# Upstream disappearance and recovery only update observations, not resources.
ONLINE=0
LAST_UPSTREAM=
mock_networksetup() { [ "$ONLINE" = 1 ] && printf 'Current Wi-Fi Network: example-upstream\n'; }
mock_ipconfig() { [ "$ONLINE" = 1 ] && printf '192.0.2.10\n'; }
mock_route() { [ "$ONLINE" = 1 ] && printf 'gateway: 192.0.2.1\ninterface: en2\n'; }
status_write() { printf '%s:%s\n' "$1" "$2" >> "$TMP/status-events"; }
upstream_observe > /dev/null
ok grep -Fxq 'RUNNING:pending' "$TMP/status-events"
ok grep -q 'unavailable' "$ROOT_DIR/upstream-observed"
upstream_observe > /dev/null
ok test "$(wc -l < "$TMP/status-events" | tr -d ' ')" = 1
ONLINE=1; upstream_observe > /dev/null
ok test "$(wc -l < "$TMP/status-events" | tr -d ' ')" = 2
ok grep -q '192.0.2.10' "$ROOT_DIR/upstream-observed"

# Main daemon logs: real temporary files/fds and renames, with only root uid
# modeled. Actual permissions, link counts, types and inodes are still checked.
mock_log_stat() {
  local result format= previous= arg
  [ "${LOG_STAT_FAIL:-0}" = 0 ] || return 1
  result=$(/usr/bin/stat "$@") || return 1
  for arg in "$@"; do
    if [ "$previous" = -f ]; then format=$arg; break; fi
    previous=$arg
  done
  case "$format" in
    '%u:%Lp'|'%u:%Lp:%l') printf '%s:%s\n' "${LOG_FAKE_UID:-0}" "${result#*:}" ;;
    *) printf '%s\n' "$result" ;;
  esac
}
mock_log_uid() { printf '%s\n' "${LOG_CALLER_UID:-0}"; }
for name in root_object main_log_file_ok main_log_paths_ok main_log_prepare main_log_fd_ok main_logs_evidence main_logs_maintain main_logs_start main_logs_entry; do load_function "$name"; done
log_setup() {
  LOG_DIR=$1
  ROOT_DIR="$LOG_DIR/private-state"
  mkdir -p "$LOG_DIR" "$ROOT_DIR"
  chmod 755 "$LOG_DIR"
  chmod 700 "$ROOT_DIR"
  MAIN_LOG_ENABLED=0
  MAIN_LOG_STATE_VALID=1
  MAIN_LOG_LIMIT=1048576
  MAIN_LOG_ROLE=
  MAIN_LOG_OUT=
  MAIN_LOG_ERR=
  LOG_FAKE_UID=0
  LOG_STAT_FAIL=0
  LOG_CALLER_UID=0
}
log_fd_continuity() (
  log_setup "$TMP/fd-continuity"
  MAIN_LOG_LIMIT=32
  main_logs_start worker
  printf 'stdout-before-rotation-0123456789\n'
  printf 'stderr-before-rotation-0123456789\n' >&2
  main_logs_maintain
  printf 'stdout-after-rotation\n'
  printf 'stderr-after-rotation\n' >&2
  grep -Fxq 'stdout-before-rotation-0123456789' "$LOG_DIR/gateway.log.1" &&
  grep -Fxq 'stderr-before-rotation-0123456789' "$LOG_DIR/error.log.1" &&
  grep -Fxq 'stdout-after-rotation' "$LOG_DIR/gateway.log" &&
  grep -Fxq 'stderr-after-rotation' "$LOG_DIR/error.log" &&
  ! grep -q after-rotation "$LOG_DIR/gateway.log.1" &&
  ! grep -q after-rotation "$LOG_DIR/error.log.1"
)
ok log_fd_continuity
log_roles_separate() (
  log_setup "$TMP/role-separation"
  main_logs_start guardian
  printf 'guardian-out\n'; printf 'guardian-err\n' >&2
  main_logs_start worker
  printf 'worker-out\n'; printf 'worker-err\n' >&2
  grep -Fxq guardian-out "$LOG_DIR/guardian.log" &&
  grep -Fxq guardian-err "$LOG_DIR/guardian-error.log" &&
  grep -Fxq worker-out "$LOG_DIR/gateway.log" &&
  grep -Fxq worker-err "$LOG_DIR/error.log" &&
  ! grep -q worker "$LOG_DIR/guardian.log" &&
  ! grep -q worker "$LOG_DIR/guardian-error.log"
)
ok log_roles_separate
log_child_fds() (
  log_setup "$TMP/child-fds"
  MAIN_LOG_LIMIT=32
  main_logs_start guardian
  printf 'guardian-before-child\n'
  (
    main_logs_start worker
    printf 'worker-before-rotation-0123456789\n'
    printf 'worker-error-before-rotation-0123456789\n' >&2
    main_logs_maintain
    printf 'worker-after-rotation\n'
    printf 'worker-error-after-rotation\n' >&2
  )
  printf 'guardian-after-child\n'
  grep -Fxq guardian-before-child "$LOG_DIR/guardian.log" &&
  grep -Fxq guardian-after-child "$LOG_DIR/guardian.log" &&
  grep -Fxq worker-after-rotation "$LOG_DIR/gateway.log" &&
  grep -Fxq worker-error-after-rotation "$LOG_DIR/error.log" &&
  ! grep -q guardian "$LOG_DIR/gateway.log" && ! grep -q worker "$LOG_DIR/guardian.log"
)
ok log_child_fds
log_retention() (
  log_setup "$TMP/retention"
  MAIN_LOG_LIMIT=1
  main_logs_start guardian
  local n
  for n in 1 2 3 4 5 6; do printf 'out-%s\n' "$n"; printf 'err-%s\n' "$n" >&2; main_logs_maintain; done
  [ ! -s "$LOG_DIR/guardian.log" ] && [ ! -s "$LOG_DIR/guardian-error.log" ] &&
  [ ! -e "$LOG_DIR/guardian.log.4" ] && [ ! -e "$LOG_DIR/guardian-error.log.4" ] &&
  grep -Fxq out-6 "$LOG_DIR/guardian.log.1" && grep -Fxq out-5 "$LOG_DIR/guardian.log.2" && grep -Fxq out-4 "$LOG_DIR/guardian.log.3" &&
  grep -Fxq err-6 "$LOG_DIR/guardian-error.log.1" && grep -Fxq err-5 "$LOG_DIR/guardian-error.log.2" && grep -Fxq err-4 "$LOG_DIR/guardian-error.log.3"
)
ok log_retention
log_failed_restarts() (
  log_setup "$TMP/restarts"
  MAIN_LOG_LIMIT=1
  local n
  for n in 1 2 3 4 5 6; do main_logs_start guardian; printf 'startup-failure-%s\n' "$n" >&2; done
  main_logs_start guardian
  [ ! -s "$LOG_DIR/guardian-error.log" ] && [ ! -e "$LOG_DIR/guardian-error.log.4" ] &&
  grep -Fxq startup-failure-6 "$LOG_DIR/guardian-error.log.1" &&
  grep -Fxq startup-failure-4 "$LOG_DIR/guardian-error.log.3"
)
ok log_failed_restarts
log_unsafe_file() (
  local kind=$1
  log_setup "$TMP/unsafe-$kind"
  printf 'untouched\n' > "$LOG_DIR/target"
  chmod 644 "$LOG_DIR/target"
  case "$kind" in
    symlink) ln -s "$LOG_DIR/target" "$LOG_DIR/gateway.log" ;;
    hardlink) ln "$LOG_DIR/target" "$LOG_DIR/gateway.log" ;;
    archive-symlink) ln -s "$LOG_DIR/target" "$LOG_DIR/gateway.log.3" ;;
    archive-hardlink) ln "$LOG_DIR/target" "$LOG_DIR/gateway.log.3" ;;
    directory) mkdir "$LOG_DIR/gateway.log" ;;
    permissions) cp "$LOG_DIR/target" "$LOG_DIR/gateway.log"; chmod 666 "$LOG_DIR/gateway.log" ;;
    owner) cp "$LOG_DIR/target" "$LOG_DIR/gateway.log"; LOG_FAKE_UID=1 ;;
  esac
  main_logs_start worker
  printf 'must-not-write\n'
  [ "$(cat "$LOG_DIR/target")" = untouched ] && [ ! -e "$LOG_DIR/error.log" ] &&
  { [ "$kind" = owner ] || [ -f "$ROOT_DIR/logging-degraded-worker" ]; }
)
for kind in symlink hardlink archive-symlink archive-hardlink directory permissions owner; do ok log_unsafe_file "$kind"; done
log_unsafe_directory() (
  log_setup "$TMP/unsafe-directory-target"
  ln -s "$LOG_DIR" "$TMP/unsafe-directory-link"
  LOG_DIR="$TMP/unsafe-directory-link"
  main_logs_start guardian
  [ ! -e "$TMP/unsafe-directory-target/guardian.log" ] && [ ! -e "$TMP/unsafe-directory-target/guardian-error.log" ]
)
ok log_unsafe_directory
log_preserves_other_files() (
  log_setup "$TMP/preservation"
  printf 'private evidence\n' > "$LOG_DIR/other.log"
  mkdir "$LOG_DIR/recovery.synthetic"
  printf 'recovery evidence\n' > "$LOG_DIR/recovery.synthetic/evidence"
  MAIN_LOG_LIMIT=1
  main_logs_start worker
  printf 'rotate-me\n'; main_logs_maintain
  [ "$(cat "$LOG_DIR/other.log")" = 'private evidence' ] &&
  [ "$(cat "$LOG_DIR/recovery.synthetic/evidence")" = 'recovery evidence' ]
)
ok log_preserves_other_files
log_failure_nonfatal_and_recovers() (
  log_setup "$TMP/failure-recovery"
  main_logs_start worker
  LOG_STAT_FAIL=1
  main_logs_maintain
  printf 'discarded-while-unavailable\n'
  LOG_STAT_FAIL=0
  main_logs_maintain
  printf 'write-resumed\n'
  [ ! -e "$ROOT_DIR/logging-degraded-worker" ] &&
  grep -Fxq write-resumed "$LOG_DIR/gateway.log" &&
  ! grep -q discarded "$LOG_DIR/gateway.log"
)
ok log_failure_nonfatal_and_recovers
log_degraded_marker_recovers() (
  log_setup "$TMP/degraded-marker-recovery"
  printf 'target-untouched\n' > "$LOG_DIR/target"
  ln -s "$LOG_DIR/target" "$LOG_DIR/gateway.log"
  main_logs_start worker
  [ "$(cat "$ROOT_DIR/logging-degraded-worker")" = main_log_write_unavailable ] || return 1
  rm "$LOG_DIR/gateway.log"
  main_logs_maintain
  printf 'safe-write-resumed\n'
  [ ! -e "$ROOT_DIR/logging-degraded-worker" ] &&
  [ "$(cat "$LOG_DIR/target")" = target-untouched ] &&
  grep -Fxq safe-write-resumed "$LOG_DIR/gateway.log"
)
ok log_degraded_marker_recovers
log_marker_safety() (
  log_setup "$TMP/marker-safety"
  printf 'unrelated\n' > "$ROOT_DIR/unrelated"
  ln -s "$ROOT_DIR/unrelated" "$ROOT_DIR/logging-degraded-worker"
  main_logs_start worker
  [ -L "$ROOT_DIR/logging-degraded-worker" ] && [ "$(cat "$ROOT_DIR/unrelated")" = unrelated ]
)
ok log_marker_safety
log_entry_safety() (
  local kind=$1
  log_setup "$TMP/entry-$kind"
  INSTALL_DIR="$LOG_DIR/installed"
  mkdir "$INSTALL_DIR"; chmod 755 "$INSTALL_DIR"
  INSTALL_SCRIPT="$INSTALL_DIR/gateway.sh"
  printf 'fixture\n' > "$INSTALL_SCRIPT"; chmod 500 "$INSTALL_SCRIPT"
  printf 'frozen fixture\n' > "$ROOT_DIR/script"; chmod 500 "$ROOT_DIR/script"
  case "$kind" in
    preflight) main_logs_entry "$INSTALL_SCRIPT" --preflight ;;
    help) main_logs_entry "$INSTALL_SCRIPT" --help ;;
    extra) main_logs_entry "$INSTALL_SCRIPT" --service unexpected ;;
    copy) main_logs_entry "$BASE/gateway.sh" --service ;;
    nonroot) LOG_CALLER_UID=501; main_logs_entry "$INSTALL_SCRIPT" --service ;;
    wrong-worker-path) main_logs_entry "$INSTALL_SCRIPT" --worker "$ROOT_DIR" ;;
    wrong-worker-state) main_logs_entry "$ROOT_DIR/script" --worker "$TMP/unknown" ;;
    writable-script) chmod 755 "$INSTALL_SCRIPT"; main_logs_entry "$INSTALL_SCRIPT" --service ;;
  esac
  [ "$MAIN_LOG_ENABLED" = 0 ] && [ ! -e "$LOG_DIR/guardian.log" ] && [ ! -e "$LOG_DIR/gateway.log" ]
)
for kind in preflight help extra copy nonroot wrong-worker-path wrong-worker-state writable-script; do ok log_entry_safety "$kind"; done
log_journal_destination() (
  log_setup "$TMP/journal-destination"
  main_logs_start worker
  load_function log
  load_function intent
  intent runtime
  log 'ordinary-log-event'
  [ -f "$ROOT_DIR/runtime-intent" ] && grep -q ' INTENT runtime$' "$ROOT_DIR/intents" &&
  ! grep -q 'INTENT runtime' "$LOG_DIR/gateway.log" &&
  grep -q ' ordinary-log-event$' "$LOG_DIR/gateway.log" &&
  ! grep -q ordinary-log-event "$ROOT_DIR/intents"
)
ok log_journal_destination
printf 'Daemon regressions: %s passed with network command doubles. No live networking tested.\n' "$passed"

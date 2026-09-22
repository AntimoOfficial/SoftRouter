#!/bin/bash
# Exercise selected production functions with every network command replaced.
# Never source the daemon entry point or contact live networking.
set -eu
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/air-gateway-daemon-test.XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT
ROOT_DIR=$TMP/state
mkdir "$ROOT_DIR"
UPSTREAM_INTERFACE=en2
DOWNSTREAM_INTERFACE=en9
GATEWAY_ADDRESS=192.168.50.1
CLIENT_ADDRESS=192.168.50.2
TAG=air_gateway
ANCHOR=com.apple/air_gateway
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
    -e 's|/sbin/route|mock_route|g' > "$TMP/function.sh"
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
  ok grep -Fxq 'pass in quick on en2 inet proto udp from any port 67 to any port 68 tag air_gateway_dhcp no state label "gateway_dhcp_in"' "$rules"
  ok grep -Fxq 'block drop out quick inet tagged air_gateway_dhcp label "gateway_dhcp_no_transit"' "$rules"
  ok awk '/gateway_dhcp_in/ {dhcp=NR} /gateway_other_transit/ {block=NR} END {exit !(dhcp>0 && dhcp<block)}' "$rules"
done
ok grep -Fxq 'nat on en2 inet from 192.168.50.2 to any -> (en2)' "$ROOT_DIR/rules"
ok grep -Fq 'keep state (if-bound)' "$ROOT_DIR/rules"
ok grep -Fq 'block drop out quick inet tagged air_gateway label "gateway_other_egress"' "$ROOT_DIR/rules"
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
      printf '200.AirDrop\n250.ApplicationFirewall\nair_gateway\n'
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
printf 'Daemon regressions: %s passed with network command doubles. No live networking tested.\n' "$passed"

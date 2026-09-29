#!/bin/bash
# Offline evidence semantics, input validation, watchdog and output privacy checks.
set -eu
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/diagnostics/lib.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/softrouter-diagnostic-test.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
passed=0
accept() { "$@" || { echo 'Expected acceptance' >&2; exit 1; }; passed=$((passed+1)); }
reject() { if "$@"; then echo 'Expected rejection' >&2; exit 1; fi; passed=$((passed+1)); }
accept valid_interface en12
reject valid_interface 'en0;echo injected'
reject valid_interface utun0
accept valid_url https://example.com/login
accept valid_url http://example.com:8080/a%20b
reject valid_url 'https://example.com/?token=example'
reject valid_url 'https://example.com/#fragment'
reject valid_url 'file:///etc/passwd'
reject valid_url 'https://example.com/$(id)'
reject valid_url "https://user@example.com/"
accept valid_proxy http://127.0.0.1:7890
reject valid_proxy http://192.0.2.1:7890
accept valid_label org.example.gateway
reject valid_label 'org.example;id'
accept valid_ssid 'Campus Wi-Fi'
accept valid_ssid '校园无线 网络'
accept valid_ssid '12345678901234567890123456789012'
reject valid_ssid '123456789012345678901234567890123'
accept valid_ssid '网网网网网网网网网网'
reject valid_ssid '网网网网网网网网网网网'
reject valid_ssid ''
reject valid_ssid $'Campus\nInjected'
reject valid_ssid $'Campus\tInjected'
reject valid_ssid $'Campus\rInjected'
reject valid_ssid $'Campus\001Injected'
reject valid_ssid $'Campus\177Injected'
ssid_state_is() {
  local expected=$1 output=$2 wanted=$3 rc=${4:-0}
  : > "$WORK/facts.tsv"
  printf '%s\n' "$output" > "$WORK/upstream_ssid.out"
  printf '%s\n' "$rc" > "$WORK/upstream_ssid.rc"
  analyze_ssid "$expected"
  [ "$(awk -F '\t' '$1=="upstream_ssid"{print $2}' "$WORK/facts.tsv")" = "$wanted" ]
}
accept ssid_state_is 'Campus Wi-Fi' 'Current Wi-Fi Network: Campus Wi-Fi' observed
accept ssid_state_is 'Campus Wi-Fi' 'Current Wi-Fi Network: Downstream' attention
accept ssid_state_is 'Campus Wi-Fi' 'Current AirPort Network: Campus Wi-Fi' observed
accept ssid_state_is '校园无线 网络' 'Current Wi-Fi Network: 校园无线 网络' observed
accept ssid_state_is 'Campus ' 'Current Wi-Fi Network: Campus ' observed
accept ssid_state_is 'Campus ' 'Current Wi-Fi Network: Campus' attention
accept ssid_state_is 'Campus' 'You are not associated with an AirPort network.' attention
accept ssid_state_is 'Campus' 'You are not associated with a Wi-Fi network.' attention
accept ssid_state_is 'Campus' 'Current Wi-Fi Network: Campus' unknown 1
accept ssid_state_is 'Campus' 'Current Wi-Fi Network: Campus' unknown 124
accept ssid_state_is 'Campus' '' unknown
accept ssid_state_is 'Campus' 'Error: Location services not authorized.' unknown
accept ssid_state_is 'Campus' 'Current Wi-Fi Network: <redacted>' unknown
accept ssid_state_is '<redacted>' 'Current Wi-Fi Network: <redacted>' unknown
accept ssid_state_is 'Campus' 'Current Wi-Fi Network: ' unknown
accept ssid_state_is 'Campus' $'Current Wi-Fi Network: Campus\nUnexpected output' unknown
accept ssid_state_is 'Campus' $'Current Wi-Fi Network: Campus\001' unknown
# Metacharacters are permitted SSID bytes, compared as data and never evaluated.
injection='$(touch INJECTION)'
accept valid_ssid "$injection"
ssid_injection_safe() (
  cd "$WORK"
  ssid_state_is "$injection" "Current Wi-Fi Network: $injection" observed &&
    ! grep -Fq "$injection" "$WORK/facts.tsv" && [ ! -e INJECTION ]
)
accept ssid_injection_safe
accept ssid_state_is 'private-expected' 'Current Wi-Fi Network: private-actual' attention
! grep -q 'private-' "$WORK/facts.tsv"; passed=$((passed+1))
for name in launch status boot_uuid forwarding guardian worker; do echo 0 > "$WORK/$name.rc"; done
cat > "$WORK/launch.out" <<'EOF'
state = running
runs = 1
pid = 100
EOF
cat > "$WORK/status.out" <<'EOF'
state=RUNNING
boot_session=SYNTHETIC-BOOT
guardian_pid=100
worker_pid=101
EOF
printf 'SYNTHETIC-BOOT\n' > "$WORK/boot_uuid.out"
echo 1 > "$WORK/forwarding.out"
echo '100 1 02-03:00:00 Tue Sep 22 10:00:00 2026' > "$WORK/guardian.out"
echo '101 100 02-03:00:00 Tue Sep 22 10:00:01 2026' > "$WORK/worker.out"
state_is() {
  : > "$WORK/facts.tsv"
  analyze_service
  [ "$(awk -F '\t' '$1=="service"{print $2}' "$WORK/facts.tsv")" = "$1" ]
}
accept state_is observed
printf 'PREVIOUS-BOOT\n' > "$WORK/boot_uuid.out"
accept state_is attention
printf 'SYNTHETIC-BOOT\n' > "$WORK/boot_uuid.out"
echo '101 999 00:01:00 date' > "$WORK/worker.out"
accept state_is unknown
echo '101 100 00:01:00 date' > "$WORK/worker.out"
echo 1 > "$WORK/status.rc"
accept state_is unknown
echo 0 > "$WORK/status.rc"
echo 0 > "$WORK/forwarding.out"
accept state_is attention
echo 1 > "$WORK/forwarding.out"
cat > "$WORK/history.out" <<'EOF'
2026-01-01 01:00:00.000 eapolclient EAP Success from private-device-identity
EAP Success: duplicated body continuation
2026-01-01 01:00:00.000 eapolclient EAP Success duplicate structured line
2026-01-01 01:00:00.001 configd en0: Wi-Fi roam private-network-name
2026-01-01 01:00:03.000 configd DHCP en0: BOUND private-address
2026-01-01 01:00:04.000 eapolclient EAP Failure identity=private-account
EOF
parse_events
[ "$(wc -l < "$WORK/events.tsv" | tr -d ' ')" = 4 ]
! grep -q 'private-' "$WORK/events.tsv"
passed=$((passed+2))
run_bounded deadline 1 /bin/sleep 5
[ "$(cat "$WORK/deadline.rc")" = 124 ]; passed=$((passed+1))
run_bounded fast 2 /usr/bin/printf 'complete'
accept command_ok fast
: > "$WORK/facts.tsv"
record label observed 'quote" backslash\ <script> | 中文'
record service unknown 'missing evidence'
record upstream_ssid attention '当前上游 Wi-Fi 与显式期望名称不一致；未保留名称'
printf 'https://example.com/\tdirect\t28\t000\t8.0\n' > "$WORK/probes.tsv"
awk -v out="$WORK" -f "$BASE/diagnostics/render.awk" "$WORK/facts.tsv" "$WORK/events.tsv" "$WORK/probes.tsv"
python3 - "$WORK" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);d=json.loads((p/'report.json').read_text())
assert d['availability_percent'] is None and d['downstream_verified'] is False
assert d['facts'][0]['value']=='quote" backslash\\ <script> | 中文'
assert d['facts'][1]['state']=='unknown'
assert d['facts'][2]['id']=='upstream_ssid' and d['facts'][2]['state']=='attention'
assert '上游 Wi-Fi 名称一致性' in (p/'report.md').read_text()
assert d['probes'][0]['curl_exit']=='28'
assert '传输成功' not in d['probes'][0]['assessment']
assert '<script>' not in (p/'report.md').read_text()
assert len(d['events'])==4
PY
passed=$((passed+9))
for n in $(seq 1 400); do printf '2026-01-01 01:%s:00.000 configd DHCP en0: BOUND\n' "$n"; done > "$WORK/history.out"
parse_events
[ "$(wc -l < "$WORK/events.tsv" | tr -d ' ')" = 300 ]; passed=$((passed+1))
/bin/bash "$BASE/diagnose.sh" --help >/dev/null
if /bin/bash "$BASE/diagnose.sh" --days 99 >/dev/null 2>&1; then exit 1; fi
if /bin/bash "$BASE/diagnose.sh" --expected-ssid $'Campus\nInjected' >/dev/null 2>&1; then exit 1; fi
if /bin/bash "$BASE/diagnose.sh" --expected-ssid '网网网网网网网网网网网' >/dev/null 2>&1; then exit 1; fi
if /bin/bash "$BASE/diagnose.sh" --expected-ssid >/dev/null 2>&1; then exit 1; fi
passed=$((passed+5))
printf 'Diagnostic checks: %s passed using synthetic evidence; no live network calls.\n' "$passed"

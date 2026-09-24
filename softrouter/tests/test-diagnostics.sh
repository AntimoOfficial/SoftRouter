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
printf 'https://example.com/\tdirect\t28\t000\t8.0\n' > "$WORK/probes.tsv"
awk -v out="$WORK" -f "$BASE/diagnostics/render.awk" "$WORK/facts.tsv" "$WORK/events.tsv" "$WORK/probes.tsv"
python3 - "$WORK" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);d=json.loads((p/'report.json').read_text())
assert d['availability_percent'] is None and d['downstream_verified'] is False
assert d['facts'][0]['value']=='quote" backslash\\ <script> | 中文'
assert d['facts'][1]['state']=='unknown'
assert d['probes'][0]['curl_exit']=='28'
assert '传输成功' not in d['probes'][0]['assessment']
assert '<script>' not in (p/'report.md').read_text()
assert len(d['events'])==4
PY
passed=$((passed+7))
for n in $(seq 1 400); do printf '2026-01-01 01:%s:00.000 configd DHCP en0: BOUND\n' "$n"; done > "$WORK/history.out"
parse_events
[ "$(wc -l < "$WORK/events.tsv" | tr -d ' ')" = 300 ]; passed=$((passed+1))
/bin/bash "$BASE/diagnose.sh" --help >/dev/null
if /bin/bash "$BASE/diagnose.sh" --days 99 >/dev/null 2>&1; then exit 1; fi
passed=$((passed+2))
printf 'Diagnostic checks: %s passed using synthetic evidence; no live network calls.\n' "$passed"

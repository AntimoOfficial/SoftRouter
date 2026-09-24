#!/bin/bash
# Nonprivileged, bounded evidence collection. No PF, routes, DNS or service mutations.
set -eu
set -o pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
BASE=$(cd -P "$(dirname "$0")" && pwd)
. "$BASE/diagnostics/lib.sh"
usage() {
  cat <<'EOF'
Usage: /bin/bash diagnose.sh [--days 1..7] [--output-dir EXISTING_DIRECTORY]
       [--upstream enN] [--downstream enN] [--url PUBLIC_HTTP_URL ...]
       [--proxy http://127.0.0.1:PORT] [--skip-history]
       [--label LAUNCHD_LABEL] [--log-dir ABSOLUTE_DIRECTORY]
Defaults: 3 days, current directory, org.softrouter.gateway, /Library/Logs/SoftRouter.
No sudo. Output: a new private directory with report.md, report.json and evidence.tsv.
No web probes unless --url is provided (maximum five). --proxy adds a local proxy comparison.
URLs cannot contain credentials, query strings or fragments. No passwords or subscriptions.
A complete report does not mean a healthy network. Missing evidence is reported as unknown.
EOF
}
fail() { printf 'SoftRouter diagnosis: %s\n' "$*" >&2; exit 2; }
DAYS=3; OUTPUT=$PWD; UPSTREAM=; DOWNSTREAM=; PROXY=; HISTORY=1
LABEL=org.softrouter.gateway; LOGS=/Library/Logs/SoftRouter
URLS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --skip-history) HISTORY=0; shift; continue ;;
    --days|--output-dir|--upstream|--downstream|--url|--proxy|--label|--log-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail 'Missing argument.' ;;
    *) fail 'Unknown option. Use --help.' ;;
  esac
  case "$1" in
    --days) [[ "$2" =~ ^[1-7]$ ]] || fail 'Days must be 1 through 7.'; DAYS=$2 ;;
    --output-dir) OUTPUT=$2 ;;
    --upstream) valid_interface "$2" || fail 'Expected an en-number interface.'; UPSTREAM=$2 ;;
    --downstream) valid_interface "$2" || fail 'Expected an en-number interface.'; DOWNSTREAM=$2 ;;
    --url) valid_url "$2" || fail 'Expected a public HTTP(S) URL without credentials, query or fragment.'; URLS+=("$2") ;;
    --proxy) valid_proxy "$2" || fail 'Only an explicitly selected loopback HTTP proxy is supported.'; PROXY=$2 ;;
    --label) valid_label "$2" || fail 'Invalid launchd label.'; LABEL=$2 ;;
    --log-dir) case "$2" in /*) LOGS=$2 ;; *) fail 'Log directory must be absolute.' ;; esac ;;
  esac
  shift 2
done
[ "${#URLS[@]}" -le 5 ] || fail 'At most five URLs per report.'
[ "$(uname -s)" = Darwin ] || fail 'Run this collector on macOS.'
[ "$(id -u)" != 0 ] || fail 'Run without sudo; unavailable privileged evidence will be marked unknown.'
[ -d "$OUTPUT" ] || fail 'The output parent directory must already exist.'
case "$OUTPUT$LOGS" in *$'\n'*|*$'\r'*|*$'\t'*) fail 'Paths cannot contain control characters.' ;; esac
OUTPUT=$(cd -P "$OUTPUT" && pwd)
REPORT=$(mktemp -d "$OUTPUT/softrouter-report-$(date '+%Y%m%d-%H%M%S').XXXXXXXX")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/softrouter-diagnose.XXXXXXXX")
ACTIVE_PID=; GUARD_PID=
cleanup() {
  [ -z "$ACTIVE_PID" ] || kill -TERM "$ACTIVE_PID" 2>/dev/null || :
  [ -z "$GUARD_PID" ] || kill -TERM "$GUARD_PID" 2>/dev/null || :
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT HUP TERM
: > "$WORK/facts.tsv"; : > "$WORK/events.tsv"; : > "$WORK/probes.tsv"
record collected_at observed "$(date '+%Y-%m-%d %H:%M:%S %z')"
record label observed "$LABEL"
record window observed "$DAYS days; $(date -v-"${DAYS}"d '+%Y-%m-%d %H:%M:%S') to $(date '+%Y-%m-%d %H:%M:%S')"
printf 'Collecting local state (no network settings will change)…\n'
run_bounded launch 5 /bin/launchctl print "system/$LABEL"
# Read only the small status file; never source it, the private config, or recovery state.
if [ -f "$LOGS/status.txt" ] && [ ! -L "$LOGS/status.txt" ] && [ -r "$LOGS/status.txt" ] &&
   [ "$(stat -f %z "$LOGS/status.txt")" -le 16384 ]; then
  run_bounded status 3 /bin/cat "$LOGS/status.txt"
else : > "$WORK/status.out"; echo 1 > "$WORK/status.rc"; fi
run_bounded enabled 4 /bin/launchctl print-disabled system
run_bounded boot_uuid 3 /usr/sbin/sysctl -n kern.bootsessionuuid
run_bounded boot_time 3 /usr/sbin/sysctl -n kern.boottime
run_bounded forwarding 3 /usr/sbin/sysctl -n net.inet.ip.forwarding
run_bounded route 4 /sbin/route -n get default
run_bounded dns 4 /usr/sbin/scutil --dns
run_bounded proxy 4 /usr/sbin/scutil --proxy
run_bounded power 4 /usr/bin/pmset -g
run_bounded battery 4 /usr/bin/pmset -g batt
for role in guardian worker; do
  pid=$(field "$WORK/status.out" "${role}_pid")
  if [[ "$pid" =~ ^[1-9][0-9]{0,8}$ ]]; then
    run_bounded "$role" 3 /bin/ps -p "$pid" -o pid=,ppid=,etime=,lstart=
  else : > "$WORK/$role.out"; echo 1 > "$WORK/$role.rc"; fi
done
analyze_service
observation enabled "$(awk -v label="$LABEL" 'index($0, "\"" label "\"") {print;exit}' "$WORK/enabled.out")"
observation boot_time "$(cat "$WORK/boot_time.out")"
observation forwarding "$(cat "$WORK/forwarding.out")"
route_iface=$(awk '$1=="interface:"{print $2}' "$WORK/route.out")
observation route "$(awk '$1=="gateway:" || $1=="interface:"{printf "%s %s; ",$1,$2}' "$WORK/route.out")"
if [ -z "$UPSTREAM" ]; then
  UPSTREAM=$(field "$WORK/status.out" upstream_interface)
  if ! valid_interface "$UPSTREAM"; then UPSTREAM=$route_iface; fi
fi
if [ -z "$DOWNSTREAM" ]; then DOWNSTREAM=$(field "$WORK/status.out" downstream_interface); fi
if valid_interface "$UPSTREAM"; then
  record upstream observed "$UPSTREAM（显式指定、状态文件或当前默认接口；未验证 SSID 绑定）"
  if [ -n "$route_iface" ] && [ "$route_iface" != "$UPSTREAM" ]; then record route_binding attention '默认出口与选定上游接口不一致'; fi
  run_bounded upstream_link 4 /sbin/ifconfig "$UPSTREAM"
  run_bounded lease 4 /usr/sbin/ipconfig getsummary "$UPSTREAM"
  observation upstream_link "$(awk '/status:|^[[:space:]]*inet /{print}' "$WORK/upstream_link.out")"
  observation lease "$(awk '/LeaseStartTime :|LeaseExpirationTime :|State : BOUND|RouterARPVerified :/{print}' "$WORK/lease.out")"
else record upstream unknown '未识别到 en 接口；不猜测上游'; fi
if valid_interface "$DOWNSTREAM"; then
  record downstream observed "$DOWNSTREAM"
  run_bounded downstream_link 4 /sbin/ifconfig "$DOWNSTREAM"
  run_bounded counters 4 /usr/sbin/netstat -ibn -I "$DOWNSTREAM"
  observation downstream_link "$(awk '/status:|media:|^[[:space:]]*inet /{print}' "$WORK/downstream_link.out")"
  observation counters "$(awk '/<Link#/{print "in_packets=" $5 "; in_errors=" $6 "; in_bytes=" $7 "; out_packets=" $8 "; out_errors=" $9 "; out_bytes=" $10}' "$WORK/counters.out")"
else record downstream unknown '未提供下游接口且状态文件没有接口字段；请核对后传 --downstream'; fi
observation dns "$(awk '/nameserver\[[0-9]+\]/{print $3}' "$WORK/dns.out" | sort -u | tr '\n' ' ')"
observation proxy "$(awk '$1 ~ /^(HTTPEnable|HTTPSEnable|HTTPProxy|HTTPPort|HTTPSProxy|HTTPSPort|SOCKSEnable|ProxyAutoConfigEnable)$/ {print $1 "=" $3}' "$WORK/proxy.out")"
observation power "$(awk '/SleepDisabled|^[[:space:]]*sleep /{print $1 "=" $2}' "$WORK/power.out")"
observation battery "$(awk '/Now drawing from/{print} /charged|charging|discharging/{sub(/^.*\t/, "");print}' "$WORK/battery.out")"
for name in gateway error; do
  if [ -f "$LOGS/$name.log" ] && [ ! -L "$LOGS/$name.log" ]; then
    record "${name}_log" observed "$(stat -f 'modified=%Sm; bytes=%z' -t '%Y-%m-%d %H:%M:%S %z' "$LOGS/$name.log")"
  else record "${name}_log" unknown '日志文件不存在或不可访问'; fi
done
record pf unknown '未请求管理员权限；没有读取实时 PF 规则或连接计数'
record downstream_access unverified '未在真实下游客户端验证；Mac 请求成功不能替代下游验收'
if [ "$HISTORY" = 1 ]; then
  printf 'Inspecting bounded historical events (up to 20 seconds)…\n'
  predicate='((process == "eapolclient" OR process == "airportd") AND (eventMessage CONTAINS[c] "EAP Success" OR eventMessage CONTAINS[c] "EAP Failure" OR eventMessage CONTAINS[c] "authentication failed" OR eventMessage CONTAINS[c] "Unexpected link down" OR eventMessage CONTAINS[c] "disassociated")) OR (process == "configd" AND (eventMessage CONTAINS[c] "Wi-Fi roam" OR eventMessage CONTAINS[c] "DHCP en"))'
  run_bounded history 20 /usr/bin/log show --start "$(date -v-"${DAYS}"d '+%Y-%m-%d %H:%M:%S')" --end "$(date '+%Y-%m-%d %H:%M:%S')" --style compact --info --predicate "$predicate"
  parse_events
  if command_ok history; then record history observed '条件检索完成；最多保留 300 条事件，未证明系统日志完整覆盖整个时间窗'
  else record history unknown '检索失败、超时或达到输出限制；已有事件仅为部分结果，空白不代表零故障'; fi
else record history unverified '用户选择跳过历史日志'; fi
index=0
for url in "${URLS[@]-}"; do
  [ -n "$url" ] || continue
  for mode in direct proxy; do
    [ "$mode" != proxy ] || [ -n "$PROXY" ] || continue
    index=$((index+1))
    args=(--disable --silent --show-error --location --max-redirs 4 --connect-timeout 3 --max-time 8 --max-filesize 1048576 --proto '=http,https' --proto-redir '=http,https' --output "$WORK/body" --write-out '%{http_code}\t%{time_total}')
    if [ "$mode" = direct ]; then args+=(--noproxy '*'); else args+=(--proxy "$PROXY" --noproxy ''); fi
    run_bounded "probe$index" 10 /usr/bin/curl "${args[@]}" "$url"
    # A status code alone is not application validation; do not save cookies or HTML.
    printf '%s\t%s\t%s\t%s\n' "$url" "$mode" "$(cat "$WORK/probe$index.rc")" "$(cat "$WORK/probe$index.out")" >> "$WORK/probes.tsv"
    /bin/rm -f "$WORK/body"
  done
done
awk -v out="$REPORT" -f "$BASE/diagnostics/render.awk" "$WORK/facts.tsv" "$WORK/events.tsv" "$WORK/probes.tsv"
cat "$WORK/facts.tsv" > "$REPORT/evidence.tsv"
printf 'REPORT_DIR=%s\n' "$REPORT"
printf 'Report generated. Read unknown/unverified items; this is not an online-rate measurement.\n'

#!/bin/bash
# Read-only collector helpers; Bash 3.2. Never evaluate configuration as code.
# Byte-wise AWK escaping preserves UTF-8 even when the caller has an invalid locale.
LC_ALL=C
export LC_ALL
valid_interface() { [[ "$1" =~ ^en[0-9]+$ ]]; }
valid_label() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]]; }
valid_url() {
  # No credentials, query strings, fragments, whitespace or shell/Markdown syntax.
  # Targets are explicitly chosen public HTTP(S) pages, never a private subscription.
  [[ "$1" =~ ^https?://[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]{1,5})?(/[a-zA-Z0-9._~/%+-]*)?$ ]] &&
    [ "${#1}" -le 512 ]
}
valid_proxy() { [[ "$1" =~ ^http://(127\.0\.0\.1|localhost):[0-9]{1,5}$ ]]; }
# Every observation has a result independent of its content. Empty/failed != healthy.
record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "$3" | /usr/bin/tr '\t\r\n' '   ')" >> "$WORK/facts.tsv"
}
run_bounded() {
  local name=$1 limit=$2 pid guard rc
  shift 2
  (ulimit -f 4096; exec "$@") > "$WORK/$name.out" 2> "$WORK/$name.err" &
  pid=$!; ACTIVE_PID=$pid
  # A reaped command cancels the watchdog. No process groups or unrelated jobs killed.
  (
    /bin/sleep "$limit"
    if kill -0 "$pid" 2>/dev/null; then
      : > "$WORK/$name.timeout"
      kill -TERM "$pid" 2>/dev/null || :
      /bin/sleep 1
      kill -KILL "$pid" 2>/dev/null || :
    fi
  ) &
  guard=$!; GUARD_PID=$guard
  if wait "$pid" 2>/dev/null; then rc=0; else rc=$?; fi
  kill "$guard" 2>/dev/null || :
  wait "$guard" 2>/dev/null || :
  ACTIVE_PID=; GUARD_PID=
  if [ -f "$WORK/$name.timeout" ]; then rc=124; fi
  printf '%s\n' "$rc" > "$WORK/$name.rc"
  return 0
}
command_ok() { [ -f "$WORK/$1.rc" ] && [ "$(cat "$WORK/$1.rc")" = 0 ]; }
observation() {
  local name=$1 value=$2
  if command_ok "$name" && [ -n "$value" ]; then record "$name" observed "$value"
  elif [ "$(cat "$WORK/$name.rc" 2>/dev/null)" = 124 ]; then record "$name" unknown '检查超时；不能据此判断正常或异常'
  else record "$name" unknown '未取得有效结果；可能未安装、权限不足或命令不可用'; fi
}
field() { /usr/bin/awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/, ""); print; exit}' "$1"; }
launch_field() { /usr/bin/awk -v key="$2" '$1==key && $2=="=" {sub(/^[^=]*= */, "");print;exit}' "$1"; }
analyze_service() {
  local state pid recorded worker boot current_boot worker_ppid live_state forwarding
  state=$(launch_field "$WORK/launch.out" state)
  pid=$(launch_field "$WORK/launch.out" pid)
  recorded=$(field "$WORK/status.out" guardian_pid)
  worker=$(field "$WORK/status.out" worker_pid)
  boot=$(field "$WORK/status.out" boot_session)
  current_boot=$(cat "$WORK/boot_uuid.out")
  live_state=$(field "$WORK/status.out" state)
  forwarding=$(cat "$WORK/forwarding.out")
  worker_ppid=$(/usr/bin/awk 'NR==1 {print $2}' "$WORK/worker.out")
  if ! command_ok launch || ! command_ok status || ! command_ok boot_uuid || ! command_ok forwarding; then
    record service unknown '证据不全：不能仅凭磁盘上的 RUNNING 判断当前服务正常'
  elif [ "$state" != running ] || [ "$live_state" != RUNNING ] || [ "$forwarding" != 1 ]; then
    record service attention '服务未满足 RUNNING、launchd running 与 IPv4 转发开启的联合条件'
  elif [ -z "$boot" ] || [ "$boot" != "$current_boot" ] || [ -z "$pid" ] || [ "$pid" != "$recorded" ]; then
    record service attention '状态文件与当前启动会话或 launchd PID 不一致，可能是旧记录'
  elif ! command_ok guardian || ! command_ok worker || [ "$worker_ppid" != "$pid" ] ||
       [ "$(/usr/bin/awk 'NR==1{print $1}' "$WORK/guardian.out")" != "$pid" ] ||
       [ "$(/usr/bin/awk 'NR==1{print $1}' "$WORK/worker.out")" != "$worker" ]; then
    record service unknown '未确认守护进程与转发进程同时存活且父子关系匹配'
  else
    record service observed '服务与转发进程存活，状态与本次系统启动一致；这不证明下游互联网可用'
  fi
  observation launch "state=$state; pid=$pid; runs=$(launch_field "$WORK/launch.out" runs)"
  observation guardian "$(cat "$WORK/guardian.out")"
  observation worker "$(cat "$WORK/worker.out")"
}
parse_events() {
  # Only fixed event names and timestamps are retained; no SSID/BSSID, identity or raw EAP packets.
  /usr/bin/awk '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
      kind=""; line=tolower($0)
      if(index(line,"eap failure") || index(line,"authentication failed")) kind="认证失败"
      else if(index(line,"eap success")) kind="认证成功"
      else if(index(line,"wi-fi roam")) kind="无线漫游"
      else if(line ~ /dhcp en[0-9]+: renew/) kind="DHCP 续租开始"
      else if(line ~ /dhcp en[0-9]+: bound/) kind="DHCP 租约确认"
      else if(index(line,"no server")) kind="DHCP 未获服务器回复"
      else if(index(line,"unexpected link down") || index(line,"disassociated")) kind="无线断链"
      key=$1 " " $2 "\t" kind
      if(kind!="" && !seen[key]++) {print key; if(++count==300) exit}
    }' "$WORK/history.out" > "$WORK/events.tsv"
}

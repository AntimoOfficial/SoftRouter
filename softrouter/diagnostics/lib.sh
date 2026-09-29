#!/bin/bash
# Read-only collector helpers; Bash 3.2. Never evaluate configuration as code.
# Byte-wise AWK escaping preserves UTF-8 even when the caller has an invalid locale.
LC_ALL=C
export LC_ALL
valid_interface() { [[ "$1" =~ ^en[0-9]+$ ]]; }
valid_label() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]]; }
# LC_ALL=C makes this the SSID byte length; shell metacharacters remain literal data.
valid_ssid() { [ -n "$1" ] && [ "${#1}" -le 32 ] && [[ ! "$1" =~ [[:cntrl:]] ]]; }
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
power_source_value() {
  if ! command_ok battery || [ ! -r "$WORK/battery.out" ]; then printf 'unknown\n'; return; fi
  # The exact first-line header is authoritative; mentions inside battery details are not.
  /usr/bin/awk '
    NR==1 {
      if($0=="Now drawing from \047AC Power\047") source="AC"
      else if($0=="Now drawing from \047Battery Power\047") source="battery"
      else if($0=="Now drawing from \047UPS Power\047") source="UPS"
    }
    /^Now drawing from/ {headers++}
    END {print (source!="" && headers==1)?source:"unknown"}
  ' "$WORK/battery.out"
}
power_setting_value() {
  local name=$1 key=$2 profile=${3:-}
  if ! command_ok "$name" || [ ! -r "$WORK/$name.out" ]; then printf 'unknown\n'; return; fi
  # Multiple, malformed or missing values are unknown, even if one line looks valid.
  /usr/bin/awk -v key="$key" -v profile="$profile" '
    /^[^[:space:]].*:$/ {section=$0; sub(/:$/, "", section); if(section==profile) sections++}
    $1==key && (profile=="" || section==profile) {
      count++; line=$0
      if(key=="SleepDisabled") {
        if(line ~ /^[[:space:]]*SleepDisabled[[:space:]]+[01][[:space:]]*$/) value=$2
      } else if(line ~ /^[[:space:]]*sleep[[:space:]]+[0-9]+([[:space:]]+\(sleep prevented by [^)]+\))?[[:space:]]*$/ && length($2)<=9) value=$2
    }
    END {print (count==1 && value!="" && (profile=="" || sections==1))?value:"unknown"}
  ' "$WORK/$name.out"
}
analyze_power() {
  local source global idle profile configured prefix state
  source=$(power_source_value)
  if [ "$source" = unknown ]; then
    record power_source unknown 'unknown；供电来源缺失、矛盾、格式不可识别，或命令失败/超时'
  else record power_source observed "$source"; fi
  global=$(power_setting_value power SleepDisabled)
  idle=$(power_setting_value power sleep)
  case "$source" in
    AC) profile='AC Power' ;;
    battery) profile='Battery Power' ;;
    UPS) profile='UPS Power' ;;
    *) profile= ;;
  esac
  configured=unknown
  [ -z "$profile" ] || configured=$(power_setting_value power_custom sleep "$profile")
  if [ "$global" = unknown ] || [ "$idle" = unknown ] || [ "$source" = unknown ] || [ "$configured" = unknown ]; then
    record sleep_policy unknown '无法完整核实供电来源、整机全局禁睡与对应闲置睡眠设置；缺失、格式异常或命令失败/超时不能解释为合盖支持'
    return
  fi
  if [ "$idle" != "$configured" ]; then
    record sleep_policy unknown '当前闲置睡眠值与对应供电配置不一致；可能在采集期间切换供电或设置，未判断合盖支持'
    return
  fi
  if [ "$idle" = 0 ]; then prefix="$source 闲置睡眠计时为 0（不因闲置计时进入睡眠）"
  else prefix="$source 闲置睡眠计时为 $idle 分钟"; fi
  state=observed
  if [ "$global" = 1 ]; then
    prefix="SleepDisabled=1，整机全局禁睡已开启，并非仅限接电；$prefix"
    case "$source" in
      battery) state=attention; prefix="$prefix；当前正在使用电池，全局禁睡可能持续耗电，不能套用持续接电的合盖实测结论" ;;
      UPS) state=attention; prefix="$prefix；当前由 UPS 供电，不能视为持续交流供电或长期运行保证" ;;
      AC) prefix="$prefix；当前接电仅为瞬时观察，未验证合盖期间供电连续性" ;;
    esac
  else prefix="SleepDisabled=0，未开启整机全局禁睡；$prefix"; fi
  record sleep_policy "$state" "$prefix；闲置睡眠设置不能证明合盖、网卡持续工作或真实下游可用"
}
analyze_lid() {
  local value=unknown
  if command_ok lid && [ -r "$WORK/lid.out" ]; then
    value=$(/usr/bin/awk '
      /^[[:space:]|]*"AppleClamshellState"[[:space:]]*=/ {
        count++
        if($0 ~ /^[[:space:]|]*"AppleClamshellState"[[:space:]]*=[[:space:]]*Yes[[:space:]]*$/) value="closed"
        else if($0 ~ /^[[:space:]|]*"AppleClamshellState"[[:space:]]*=[[:space:]]*No[[:space:]]*$/) value="open"
      }
      END {print (count==1 && value!="")?value:"unknown"}
    ' "$WORK/lid.out")
  fi
  case "$value" in
    open) record lid_state observed 'open；采集时机盖打开，未测量合盖期间状态' ;;
    closed) record lid_state observed 'closed；采集时机盖关闭，瞬时状态不证明合盖期间下游持续可用' ;;
    *) record lid_state unknown 'unknown；未取得唯一有效的机盖状态；可能无机盖、属性不可用或命令失败/超时' ;;
  esac
}
analyze_downstream_speed() {
  local speed=unknown
  if command_ok downstream_link && [ -r "$WORK/downstream_link.out" ]; then
    speed=$(/usr/bin/awk '
      /^[[:space:]]*status:/ {statuses++; if($0 ~ /^[[:space:]]*status:[[:space:]]+active[[:space:]]*$/) active=1}
      /^[[:space:]]*media:/ {
        medias++; line=$0; sub(/^[[:space:]]*media:[[:space:]]*/, "", line)
        if(line ~ /^autoselect[[:space:]]+\([^()]+\)[[:space:]]*$/) {
          sub(/^autoselect[[:space:]]+\(/, "", line); sub(/\)[[:space:]]*$/, "", line)
        }
        if(tolower(line) ~ /^[1-9][0-9]*g?base[a-z0-9-]+([[:space:]]+<[a-z0-9,-]+>)?[[:space:]]*$/) {
          sub(/[[:space:]].*$/, "", line); speed=line
        }
      }
      END {print (statuses==1 && active && medias==1 && speed!="")?speed:"unknown"}
    ' "$WORK/downstream_link.out")
  fi
  if [ "$speed" = unknown ]; then
    record downstream_speed unknown 'unknown；未取得活动下游链路的明确速率；未指定接口、链路未激活、输出异常或命令失败/超时'
  else record downstream_speed observed "$speed；采集时链路速率，不是吞吐测速或下游互联网验收"; fi
}
analyze_ssid() {
  local expected=$1 line= actual=
  # A successful exit alone is insufficient: newer macOS may hide Wi-Fi identity.
  # Keep only comparison evidence, never the expected or observed network name.
  if ! command_ok upstream_ssid; then
    record upstream_ssid unknown '未取得 Wi-Fi 名称；命令失败、超时或权限不足，不能判断匹配'
    return
  fi
  if [ "$(/usr/bin/awk 'END {print NR}' "$WORK/upstream_ssid.out")" != 1 ]; then
    record upstream_ssid unknown 'Wi-Fi 查询输出格式不可识别；不能判断匹配'
    return
  fi
  IFS= read -r line < "$WORK/upstream_ssid.out" || [ -n "$line" ] || :
  case "$line" in
    'Current Wi-Fi Network: '*|'Current AirPort Network: '*)
      actual=${line#*: }
      case "$actual" in
        '<redacted>'|'<unknown>'|'(null)'|'[redacted]'|'')
          record upstream_ssid unknown '系统隐藏或未提供 Wi-Fi 名称；不能判断匹配'; return ;;
      esac
      if ! valid_ssid "$actual"; then
        record upstream_ssid unknown 'Wi-Fi 查询值不可识别；不能判断匹配'
      elif [ "$actual" = "$expected" ]; then
        record upstream_ssid observed '当前上游 Wi-Fi 与显式期望名称一致；未保留名称，未验证互联网可用性'
      else
        record upstream_ssid attention '当前上游 Wi-Fi 与显式期望名称不一致；可能已切入错误网络，未保留名称'
      fi ;;
    'You are not associated with an AirPort network.'|'You are not associated with a Wi-Fi network.')
      record upstream_ssid attention '系统报告所选上游未关联 Wi-Fi；当前未满足期望连接' ;;
    *) record upstream_ssid unknown 'Wi-Fi 查询输出格式不可识别或受系统权限限制；不能判断匹配' ;;
  esac
}
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

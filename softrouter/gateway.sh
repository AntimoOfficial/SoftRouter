#!/bin/bash
# Installed root daemon. --service is the foreground launchd guardian.
# Only runtime interface/PF/forwarding changes. No upstream health exit or timer.
set -eu
set -o pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
INSTALL_DIR=/Library/SoftRouter
INSTALL_SCRIPT=$INSTALL_DIR/gateway.sh
ROOT_DIR=/private/var/run/softrouter
LOG_DIR=/Library/Logs/SoftRouter
PREFS=/Library/Preferences/SystemConfiguration/preferences.plist
ANCHOR=com.apple/softrouter
TAG=softrouter
BOOT_UUID=
SERVICE_EXIT=1
STATE_CLAIMED=0
LAST_UPSTREAM=
fail() { printf 'Gateway STOP: %s\n' "$*" >&2; exit 1; }
compact() { /usr/bin/tr -d '[:space:]'; }
is_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
pf() { /sbin/pfctl "$@" 2>> "$ROOT_DIR/pf-diagnostics.txt"; }
service_dict() { /usr/libexec/PlistBuddy -c "Print :NetworkServices:$DOWNSTREAM_SERVICE_UUID:$1" "$PREFS"; }
service_ok() {
  [ "$(service_dict UserDefinedName)" = "$DOWNSTREAM_SERVICE" ] &&
  [ "$(service_dict Interface:DeviceName)" = "$DOWNSTREAM_INTERFACE" ] &&
  [ "$(/usr/sbin/networksetup -getnetworkserviceenabled "$DOWNSTREAM_SERVICE")" = Disabled ] &&
  [ "$(service_dict IPv4 | compact)" = 'Dict{ConfigMethod=DHCP}' ] &&
  [ "$(service_dict IPv6 | compact)" = 'Dict{ConfigMethod=Automatic}' ] &&
  /sbin/ifconfig "$DOWNSTREAM_INTERFACE" | /usr/bin/awk -v mac="$DOWNSTREAM_MAC" '
    $1=="ether" {count++; if(tolower($2)!=mac) bad=1} END {exit !(count==1 && !bad)}'
}
ipv6_ok() { [ "$(/usr/sbin/sysctl -n net.inet6.ip6.forwarding)" = 0 ]; }
# ifconfig omits nd6 both when the protocol is unavailable and when flags=0.
# The read-only ndp query distinguishes them; never attach IPv6 to probe it.
ipv6_interface_mode() {
  local snapshot=$1
  ! /usr/bin/grep -Eq '^[[:space:]]+inet6 ' "$snapshot" || return 1
  if /usr/bin/grep -Eq '^[[:space:]]+nd6 options=' "$snapshot"; then
    if /usr/bin/grep -q IFDISABLED "$snapshot"; then printf 'disabled\n'; else printf 'enabled\n'; fi
    return 0
  fi
  if LC_ALL=C /usr/sbin/ndp -i "$DOWNSTREAM_INTERFACE" > "$ROOT_DIR/ipv6-query-current" 2>&1; then
    # Successful query with no printed nd6 line means attached with zero flags.
    printf 'enabled\n'
  elif /usr/bin/grep -Fxq 'ioctl (SIOCGIFINFO_IN6): Invalid argument' "$ROOT_DIR/ipv6-query-current"; then
    printf 'absent\n'
  else
    return 1
  fi
}
prepare_ipv6() {
  local baseline current
  IFS= read -r baseline < "$ROOT_DIR/ipv6-baseline"
  /sbin/ifconfig "$DOWNSTREAM_INTERFACE" > "$ROOT_DIR/downstream-ipv6-prepare" || return 1
  current=$(ipv6_interface_mode "$ROOT_DIR/downstream-ipv6-prepare") || return 1
  [ "$current" = "$baseline" ] || return 1
  case "$baseline" in
    absent) log "IPv6 unavailable on $DOWNSTREAM_INTERFACE; no IPv6 configuration command issued." ;;
    enabled)
      intent v6
      /sbin/ifconfig "$DOWNSTREAM_INTERFACE" inet6 ifdisabled || return 1
      /sbin/ifconfig "$DOWNSTREAM_INTERFACE" > "$ROOT_DIR/downstream-ipv6-disabled" || return 1
      [ "$(ipv6_interface_mode "$ROOT_DIR/downstream-ipv6-disabled")" = disabled ] || return 1
      : > "$ROOT_DIR/v6-changed"
      ;;
    *) return 1 ;;
  esac
}
ipv6_runtime_ok() {
  local baseline current
  IFS= read -r baseline < "$ROOT_DIR/ipv6-baseline" || return 1
  current=$(ipv6_interface_mode "$1") || return 1
  case "$baseline:$current" in absent:absent|enabled:disabled) return 0 ;; *) return 1 ;; esac
}
restore_ipv6() {
  local baseline current
  IFS= read -r baseline < "$ROOT_DIR/ipv6-baseline" || return 1
  /sbin/ifconfig "$DOWNSTREAM_INTERFACE" > "$ROOT_DIR/downstream-ipv6-restore" || return 1
  current=$(ipv6_interface_mode "$ROOT_DIR/downstream-ipv6-restore") || return 1
  # Intent + enabled baseline + observed disabled state covers interruption
  # after the ioctl but before v6-changed is written. No absent-protocol ioctl.
  if [ "$baseline" = enabled ] && [ "$current" = disabled ] && [ -f "$ROOT_DIR/v6-intent" ]; then
    /sbin/ifconfig "$DOWNSTREAM_INTERFACE" inet6 -ifdisabled || return 1
    /sbin/ifconfig "$DOWNSTREAM_INTERFACE" > "$ROOT_DIR/downstream-ipv6-restored" || return 1
    current=$(ipv6_interface_mode "$ROOT_DIR/downstream-ipv6-restored") || return 1
  fi
  [ "$current" = "$baseline" ]
}
root_object() {
  [ ! -L "$1" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$1")" = "0:$2" ]
}
installation_ok() {
  [ "$(/usr/bin/id -u)" = 0 ] || fail 'Installed daemon requires root.'
  root_object "$INSTALL_DIR" 755 && root_object "$INSTALL_SCRIPT" 500 || fail 'Expected root-owned installation directory 0755 and script 0500.'
  root_object "$LOG_DIR" 755 || fail 'Expected root-owned log directory 0755.'
  root_object "$INSTALL_DIR/config.sh" 500 && root_object "$INSTALL_DIR/gateway.conf" 600 || fail 'Expected root-owned configuration library 0500 and configuration file 0600.'
  . "$INSTALL_DIR/config.sh"
  load_config "$INSTALL_DIR/gateway.conf" || fail 'Invalid installed configuration.'
  BOOT_UUID=$(/usr/sbin/sysctl -n kern.bootsessionuuid)
  [[ "$BOOT_UUID" =~ ^[A-Fa-f0-9-]{36}$ ]] || fail 'Boot session identity unavailable.'
}
private_state() {
  [ "$1" = "$ROOT_DIR" ] || fail 'Invalid private state directory.'
  root_object "$ROOT_DIR" 700 && root_object "$ROOT_DIR/script" 500 || fail 'Private state/script ownership changed.'
  local saved_boot
  IFS= read -r saved_boot < "$ROOT_DIR/boot-session"
  [ "$saved_boot" = "$BOOT_UUID" ] || fail 'Worker belongs to a different boot session.'
  load_frozen_config
}
load_frozen_config() {
  root_object "$ROOT_DIR/config.sh" 500 && root_object "$ROOT_DIR/gateway.conf" 600 || fail 'Private configuration ownership changed.'
  . "$ROOT_DIR/config.sh"
  load_config "$ROOT_DIR/gateway.conf" || fail 'Invalid private configuration.'
}
status_write() {
  local tmp
  tmp=$(/usr/bin/mktemp "$LOG_DIR/.status.XXXXXXXX") || return 1
  {
    printf 'state=%s\ncleanup_ok=%s\nmessage=%s\n' "$1" "$2" "$3"
    printf 'forwarding=%s\n' "$(/usr/sbin/sysctl -n net.inet.ip.forwarding 2>/dev/null || printf unknown)"
    printf 'updated_utc=%s\nboot_session=%s\nstate_directory=%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$BOOT_UUID" "$ROOT_DIR"
    [ ! -s "$ROOT_DIR/guardian-pid" ] || { printf 'guardian_pid='; /bin/cat "$ROOT_DIR/guardian-pid"; }
    [ ! -s "$ROOT_DIR/worker-pid" ] || { printf 'worker_pid='; /bin/cat "$ROOT_DIR/worker-pid"; }
  } > "$tmp"
  /bin/chmod 644 "$tmp"
  /bin/mv -f "$tmp" "$LOG_DIR/status.txt"
}
log() { printf '%s %s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
intent() {
  : > "$ROOT_DIR/$1-intent"
  log "INTENT $1" >> "$ROOT_DIR/intents"
}
archive_state() {
  local archive
  archive=$(/usr/bin/mktemp -d "$LOG_DIR/recovery.XXXXXXXX") || return 1
  /bin/chmod 700 "$archive"
  /bin/mv "$ROOT_DIR" "$archive/runstate" || return 1
  log "Private state archived: $archive/runstate"
}
claim_state() {
  local old_boot inode claim
  if [ -e "$ROOT_DIR" ] || [ -L "$ROOT_DIR" ]; then
    root_object "$ROOT_DIR" 700 || fail 'Unexpected state path ownership; not touched.'
    IFS= read -r old_boot < "$ROOT_DIR/boot-session" || fail 'State has no boot identity; fail closed.'
    [[ "$old_boot" =~ ^[A-Fa-f0-9-]{36}$ ]] || fail 'Invalid saved boot identity; fail closed.'
    if [ "$old_boot" = "$BOOT_UUID" ]; then
      # A live instance or an unclean same-boot SIGKILL can own these resources.
      # Do not steal its token, kill its process, or interpret its PID as ours.
      status_write ATTENTION 0 'Same-boot state already exists; inspect existing instance/recovery before restarting.'
      fail 'Same-boot state already exists; no network changes.'
    fi
    inode=$(/usr/bin/stat -f '%i' "$ROOT_DIR")
    claim="$ROOT_DIR/.reconcile-$BOOT_UUID"
    /bin/mkdir "$claim" || fail 'Another process is reconciling old-boot state.'
    [ "$(/usr/bin/stat -f '%i' "$ROOT_DIR")" = "$inode" ] &&
      [ "$(/bin/cat "$ROOT_DIR/boot-session")" = "$old_boot" ] || fail 'State changed while claiming it.'
    # A different boot proves old processes are gone. Preserve old evidence;
    # new strict PF/interface preflight must still pass before any mutation.
    archive_state || fail 'Could not archive previous-boot state.'
  fi
  /bin/mkdir "$ROOT_DIR" || fail 'Another gateway instance holds the state directory.'
  STATE_CLAIMED=1
  /bin/chmod 700 "$ROOT_DIR"
  printf '%s\n' "$BOOT_UUID" > "$ROOT_DIR/boot-session"
  /bin/cp "$INSTALL_SCRIPT" "$ROOT_DIR/script"
  /bin/chmod 500 "$ROOT_DIR/script"
  /bin/cp "$INSTALL_DIR/config.sh" "$ROOT_DIR/config.sh"
  /bin/cp "$INSTALL_DIR/gateway.conf" "$ROOT_DIR/gateway.conf"
  /bin/chmod 500 "$ROOT_DIR/config.sh"
  /bin/chmod 600 "$ROOT_DIR/gateway.conf"
  # Both guardian and worker use this snapshot for the entire resource lifetime.
  load_frozen_config
}
empty_refs() {
    [ "$(/usr/bin/tr -d '\r\n' < "$1")" = 'No pf starter references held' ]
}
ref_tokens() {
    /usr/bin/awk '
      /^[[:space:]]*$/ || /^TOKENS:$/ || /Process Name.*TOKEN.*TIMESTAMP/ {next}
      /^No pf starter references held$/ {next}
      $1 ~ /^[0-9]+$/ && NF >= 6 && $(NF-1)=="days" &&
        $(NF-2) ~ /^[0-9]+$/ && $NF ~ /^[0-9]+:[0-9]+:[0-9]+$/ {
        token=$(NF-3); if(token !~ /^[0-9]+$/) {bad=1; next}; print token; next
      }
      {bad=1} END {if(bad) exit 1}
    ' "$1"
}
own_token() {
    [ -f "$ROOT_DIR/enable-output" ] || return 1
    /usr/bin/sed -nE 's/^[[:space:]]*Token[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$ROOT_DIR/enable-output"
}

default_hooks() {
    pf -sn > "$ROOT_DIR/root-nat-current" || return 1
    pf -sr > "$ROOT_DIR/root-filter-current" || return 1
    /usr/bin/grep -Eq '^nat-anchor "com\.apple/\*"( all)?[[:space:]]*$' "$ROOT_DIR/root-nat-current" || return 1
    /usr/bin/grep -Eq '^anchor "com\.apple/\*"( all)?[[:space:]]*$' "$ROOT_DIR/root-filter-current" || return 1
    ! /usr/bin/grep -Ev '^[[:space:]]*((nat-anchor|rdr-anchor) "com\.apple/\*"( all)?)?[[:space:]]*$' "$ROOT_DIR/root-nat-current" >/dev/null || return 1
    ! /usr/bin/grep -Ev '^[[:space:]]*((anchor "com\.apple/\*"( all)?)|(scrub-anchor "com\.apple/\*" all fragment reassemble))?[[:space:]]*$' "$ROOT_DIR/root-filter-current" >/dev/null
}
empty_children() {
    local path kind output
    pf -s Anchors > "$ROOT_DIR/top-anchors-current" || return 1
    while IFS= read -r path; do
        path=$(printf '%s' "$path" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$path" in ''|com.apple) ;; *) return 1 ;; esac
    done < "$ROOT_DIR/top-anchors-current"
    pf -a com.apple -s Anchors > "$ROOT_DIR/children-current" || return 1
    # Tested macOS versions use these two built-in wildcard calls in the parent.
    # Permit only those calls; every referenced child is verified empty below.
    pf -a com.apple -sr > "$ROOT_DIR/apple-parent-filter-current" || return 1
    ! /usr/bin/grep -Ev '^[[:space:]]*(anchor "(200\.AirDrop|250\.ApplicationFirewall)/\*" all)?[[:space:]]*$' \
        "$ROOT_DIR/apple-parent-filter-current" >/dev/null || return 1
    [ -z "$(pf -a com.apple -sn)" ] || return 1
    while IFS= read -r path; do
        path=$(printf '%s' "$path" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$path" ] || continue
        path=${path#com.apple/}
        case "$path" in
          200.AirDrop|250.ApplicationFirewall) ;;
          "${ANCHOR#com.apple/}") [ ! -f "$ROOT_DIR/anchor-intent" ] || continue ;;
          *) return 1 ;;
        esac
        for kind in rules nat Anchors; do
            output=$(pf -a "com.apple/$path" -s "$kind") || return 1
            [ -z "$output" ] || return 1
        done
    done < "$ROOT_DIR/children-current"
}


preflight() {
  [ "$(/usr/bin/uname -s)" = Darwin ] || fail 'This daemon requires macOS.'
  service_ok && ipv6_ok || fail 'Expected disabled downstream service with DHCP/Automatic preferences and IPv6 forwarding off.'
  [ "$(/usr/sbin/sysctl -n net.inet.ip.forwarding)" = 0 ] || fail 'IPv4 forwarding is already owned by another service.'
  /usr/sbin/networksetup -listnetworkserviceorder > "$ROOT_DIR/service-order"
  [ "$(/usr/bin/awk -v iface="$DOWNSTREAM_INTERFACE" '/^\(([0-9]+|\*)\) / {name=$0;sub(/^\(([0-9]+|\*)\) /,"",name);sub(/^\*/,"",name)} index($0, "Device: " iface ")") {print name}' "$ROOT_DIR/service-order")" = "$DOWNSTREAM_SERVICE" ] || fail 'Downstream service binding is not unique.'
  /sbin/ifconfig "$UPSTREAM_INTERFACE" > "$ROOT_DIR/upstream-before" || fail 'Expected configured upstream interface.'
  /sbin/ifconfig "$DOWNSTREAM_INTERFACE" > "$ROOT_DIR/downstream-before" || fail 'Expected configured downstream interface.'
  ! /usr/bin/grep -Eq 'flags=.*[<,]UP[,>]|^[[:space:]]+inet6? |IFDISABLED' "$ROOT_DIR/downstream-before" || fail 'Downstream runtime settings already exist; fail closed.'
  ipv6_interface_mode "$ROOT_DIR/downstream-before" > "$ROOT_DIR/ipv6-baseline" || fail 'Cannot establish downstream IPv6 availability safely.'
  case "$(/bin/cat "$ROOT_DIR/ipv6-baseline")" in absent|enabled) ;; *) fail 'Unexpected initial downstream IPv6 mode.' ;; esac
  /sbin/ifconfig -a > "$ROOT_DIR/interfaces-before"
  /usr/bin/awk -v prefix="${GATEWAY_ADDRESS%.*}." '$1=="inet" && index($2,prefix)==1 {conflict=1} END {exit conflict}' "$ROOT_DIR/interfaces-before" || fail 'Gateway subnet is already in use locally.'
  local addr routefile
  for addr in "$GATEWAY_ADDRESS" "$CLIENT_ADDRESS"; do
    routefile="$ROOT_DIR/route-$addr-before"
    if /sbin/route -n get -inet "$addr" > "$routefile" 2>&1; then
      if ! /usr/bin/grep -Eq '^[[:space:]]*destination: default$' "$routefile"; then
        /usr/bin/grep -Eq 'flags: <([^>]*,)?HOST([,>])' "$routefile" &&
        /usr/bin/grep -Eq 'flags: <([^>]*,)?(WASCLONED|CLONED)([,>])' "$routefile" &&
        ! /usr/bin/grep -Eq 'flags: <([^>]*,)?STATIC([,>])' "$routefile" || fail "Explicit route occupies $addr."
      fi
    fi
  done
  pf -s info > "$ROOT_DIR/info-before"
  /usr/bin/grep -Eq '^Status: Disabled([[:space:]]|$)' "$ROOT_DIR/info-before" || fail 'PF must start disabled.'
  pf -s References > "$ROOT_DIR/references-before"
  empty_refs "$ROOT_DIR/references-before" || fail 'Existing PF references; fail closed.'
  pf -s states > "$ROOT_DIR/states-before"
  [ ! -s "$ROOT_DIR/states-before" ] || fail 'Existing PF states; fail closed.'
  default_hooks && empty_children || fail 'Unknown or nonempty PF root/child configuration; fail closed.'
  [ -z "$(pf -a "$ANCHOR" -sr)" ] && [ -z "$(pf -a "$ANCHOR" -sn)" ] || fail 'Dedicated anchor is already populated.'
  /bin/cp "$ROOT_DIR/root-nat-current" "$ROOT_DIR/root-nat-before"
  /bin/cp "$ROOT_DIR/root-filter-current" "$ROOT_DIR/root-filter-before"
  log 'Preflight OK: downstream/PF resources unowned; upstream connectivity is not a prerequisite.'
}
write_rules() {
  # Dynamic local addresses/broadcasts stop matching when an interface loses
  # them. A static self expansion could accidentally permit later transit.
  /usr/bin/awk '/^[A-Za-z][A-Za-z0-9_]*:/ {name=$1;sub(/:$/,"",name);print name}' "$ROOT_DIR/interfaces-before" > "$ROOT_DIR/interface-names"
  printf '%s\n%s\n' "$UPSTREAM_INTERFACE" "$DOWNSTREAM_INTERFACE" >> "$ROOT_DIR/interface-names"
  /usr/bin/sort -u "$ROOT_DIR/interface-names" > "$ROOT_DIR/interface-names-sorted"
  local iface
  : > "$ROOT_DIR/local-rules"
  # DHCP may unicast OFFER/ACK to an address the upstream does not own yet.
  # Accept upstream UDP 67->68 locally without state, and prohibit transit.
  printf 'pass in quick on %s inet proto udp from any port 67 to any port 68 tag %s_dhcp no state label "gateway_dhcp_in"\n' "$UPSTREAM_INTERFACE" "$TAG" >> "$ROOT_DIR/local-rules"
  printf 'block drop out quick inet tagged %s_dhcp label "gateway_dhcp_no_transit"\n' "$TAG" >> "$ROOT_DIR/local-rules"
  while IFS= read -r iface; do
    [[ "$iface" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || fail 'Unexpected local interface name.'
    printf 'pass in quick inet from any to (%s) no state\n' "$iface" >> "$ROOT_DIR/local-rules"
    printf 'pass in quick inet from any to (%s:broadcast) no state\n' "$iface" >> "$ROOT_DIR/local-rules"
  done < "$ROOT_DIR/interface-names-sorted"
  printf 'pass in quick inet from any to 224.0.0.0/4 no state\npass in quick inet from any to 255.255.255.255 no state\n' >> "$ROOT_DIR/local-rules"
  { /bin/cat "$ROOT_DIR/local-rules"; printf 'block drop in quick inet all label "gateway_other_transit"\n'; } > "$ROOT_DIR/protection-rules"
  {
    printf 'nat on %s inet from %s to any -> (%s)\n' "$UPSTREAM_INTERFACE" "$CLIENT_ADDRESS" "$UPSTREAM_INTERFACE"
    # Tag this source before every local-address exception, including stale IPs.
    printf 'pass in quick on %s inet from %s to any tag %s no state label "gateway_ingress"\n' "$DOWNSTREAM_INTERFACE" "$CLIENT_ADDRESS" "$TAG"
    /bin/cat "$ROOT_DIR/local-rules"
    printf 'block drop in quick inet all label "gateway_other_transit"\n'
    # Require a translated upstream source; an empty NAT pool must not leak the client.
    printf 'pass out quick on %s inet from (%s) to any tag %s tagged %s keep state (if-bound) label "gateway_upstream"\n' "$UPSTREAM_INTERFACE" "$UPSTREAM_INTERFACE" "$TAG" "$TAG"
    printf 'pass out quick on %s inet from !%s to %s tagged %s no state label "gateway_return"\n' "$DOWNSTREAM_INTERFACE" "$CLIENT_ADDRESS" "$CLIENT_ADDRESS" "$TAG"
    printf 'block drop out quick inet tagged %s label "gateway_other_egress"\n' "$TAG"
  } > "$ROOT_DIR/rules"
  /sbin/pfctl -n -a "$ANCHOR" -f "$ROOT_DIR/rules" > "$ROOT_DIR/parse-log" 2>&1 || fail 'PF parsing failed; no network change.'
  /sbin/pfctl -n -a "$ANCHOR" -f "$ROOT_DIR/protection-rules" >> "$ROOT_DIR/parse-log" 2>&1 || fail 'Protection parsing failed.'
}
anchor_unchanged() {
  [ -f "$ROOT_DIR/loaded-nat" ] && [ -f "$ROOT_DIR/loaded-filter" ] || return 1
  pf -a "$ANCHOR" -sn > "$ROOT_DIR/own-nat-current" && pf -a "$ANCHOR" -sr > "$ROOT_DIR/own-filter-current" &&
    /usr/bin/cmp -s "$ROOT_DIR/loaded-nat" "$ROOT_DIR/own-nat-current" &&
    /usr/bin/cmp -s "$ROOT_DIR/loaded-filter" "$ROOT_DIR/own-filter-current"
}
sole_owner() {
  local token refs
  token=$(own_token) || return 1
  [[ "$token" =~ ^[0-9]+$ ]] || return 1
  pf -s References > "$ROOT_DIR/refs-current" || return 1
  refs=$(ref_tokens "$ROOT_DIR/refs-current") || return 1
  pf -s info > "$ROOT_DIR/info-current" || return 1
  /usr/bin/grep -Eq '^Status: Enabled([[:space:]]|$)' "$ROOT_DIR/info-current" || return 1
  [ "$refs" = "$token" ] && default_hooks && empty_children && anchor_unchanged &&
    /usr/bin/cmp -s "$ROOT_DIR/root-nat-before" "$ROOT_DIR/root-nat-current" &&
    /usr/bin/cmp -s "$ROOT_DIR/root-filter-before" "$ROOT_DIR/root-filter-current"
}
runtime_owned() {
  service_ok && ipv6_ok && sole_owner || return 1
  /sbin/ifconfig "$DOWNSTREAM_INTERFACE" > "$ROOT_DIR/downstream-owned-current" || return 1
  /usr/bin/grep -Eq 'flags=.*[<,]UP[,>]' "$ROOT_DIR/downstream-owned-current" &&
    ipv6_runtime_ok "$ROOT_DIR/downstream-owned-current" &&
    /usr/bin/awk -v address="$GATEWAY_ADDRESS" '$1=="inet" {if($2==address && $3=="netmask" && $4=="0xffffff00") found++; else bad=1} $1=="inet6"{bad=1} END{exit !(found==1 && !bad)}' "$ROOT_DIR/downstream-owned-current"
}
rotate_diagnostics() {
  local bytes
  [ -f "$ROOT_DIR/pf-diagnostics.txt" ] || return 0
  bytes=$(/usr/bin/stat -f '%z' "$ROOT_DIR/pf-diagnostics.txt") || return 1
  [ "$bytes" -le 1048576 ] || /bin/mv -f "$ROOT_DIR/pf-diagnostics.txt" "$ROOT_DIR/pf-diagnostics.previous"
}
upstream_observe() {
  local report
  report=$({
    /usr/sbin/networksetup -getairportnetwork "$UPSTREAM_INTERFACE" 2>/dev/null || printf 'SSID unavailable\n'
    /usr/sbin/ipconfig getifaddr "$UPSTREAM_INTERFACE" 2>/dev/null || printf 'Upstream IPv4 unavailable\n'
    /sbin/route -n get default 2>/dev/null | /usr/bin/awk '/^[[:space:]]*(gateway|interface):/ {print}' || printf 'default route unavailable\n'
  })
  if [ "$report" != "$LAST_UPSTREAM" ]; then
    LAST_UPSTREAM=$report
    log 'UPSTREAM_CHANGED (observation only; forwarding remains active)'
    printf '%s\n' "$report"
    printf '%s\n' "$report" > "$ROOT_DIR/upstream-observed"
    status_write RUNNING pending 'Forwarding enabled; upstream connectivity is observation only.'
  fi
}
worker_matches() {
  [ "$(/bin/ps -p "$1" -o command= 2>/dev/null)" = "/bin/bash $ROOT_DIR/script --worker $ROOT_DIR" ]
}
stop_worker() {
  local pid=$1 pgid own_pgid observed remaining
  IFS= read -r pgid < "$ROOT_DIR/worker-pgid" || return 1
  is_uint "$pid" && [ "$pgid" = "$pid" ] || return 1
  own_pgid=$(/bin/ps -p "$$" -o pgid= | compact)
  [ "$pgid" != "$own_pgid" ] || return 1
  if worker_matches "$pid"; then
    observed=$(/bin/ps -p "$pid" -o pgid= | compact)
    [ "$observed" = "$pgid" ] || return 1
  elif /bin/kill -0 "$pid" 2>/dev/null; then return 1
  fi
  /bin/kill -STOP -- "-$pgid" 2>/dev/null || true
  /bin/kill -TERM -- "-$pgid" 2>/dev/null || true
  /bin/kill -CONT -- "-$pgid" 2>/dev/null || true
  /bin/sleep 1
  /bin/kill -KILL -- "-$pgid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  remaining=$(/bin/ps -axo pgid= | /usr/bin/awk -v g="$pgid" '$1==g{print}')
  [ -z "$remaining" ]
}
endpoint_states() {
  pf -s states | /usr/bin/awk -v address="$CLIENT_ADDRESS" '
    BEGIN {gsub(/\./, "[.]", address); pattern="(^|[^0-9.])" address "([^0-9.]|$)"}
    $0 ~ pattern {print}'
}
cleanup() {
  local clean=1 protect=0 token= current= output= iface_owned=0
  token=$(own_token) || token=
  [[ "$token" =~ ^[0-9]+$ ]] || token=
  current=$(/usr/sbin/sysctl -n net.inet.ip.forwarding)
  if [ -f "$ROOT_DIR/forward-intent" ] && [ "$current" = 1 ]; then
    if sole_owner; then
      /usr/sbin/sysctl -w net.inet.ip.forwarding=0 || clean=0
    else
      printf 'ATTENTION: forwarding ownership changed; global value not overwritten.\n'
      clean=0
    fi
  fi
  [ "$(/usr/sbin/sysctl -n net.inet.ip.forwarding)" = 0 ] || { clean=0; protect=1; }
  if [ -f "$ROOT_DIR/anchor-intent" ]; then
    /sbin/pfctl -k "$CLIENT_ADDRESS" || clean=0
    if [ "$protect" = 1 ]; then
      if anchor_unchanged; then
        /sbin/pfctl -a "$ANCHOR" -f "$ROOT_DIR/protection-rules" || clean=0
        # Clear again after blocking to catch states created during replacement.
        /sbin/pfctl -k "$CLIENT_ADDRESS" || clean=0
      fi
      printf 'ATTENTION: protective anchor/own reference retained: %s token=%s\n' "$ANCHOR" "$token"
    elif [ ! -f "$ROOT_DIR/loaded-filter" ] || anchor_unchanged; then
      /sbin/pfctl -a "$ANCHOR" -F nat || clean=0
      /sbin/pfctl -a "$ANCHOR" -F rules || clean=0
    else
      printf 'ATTENTION: own anchor changed externally; not overwritten.\n'; clean=0; protect=1
    fi
  fi
  if [ "$protect" = 0 ] && [ -n "$token" ]; then
    /sbin/pfctl -X "$token" || clean=0
  elif [ -f "$ROOT_DIR/enable-intent" ] && [ -z "$token" ]; then
    printf 'ATTENTION: own PF token unavailable; no global disable attempted.\n'; clean=0
  fi
  if [ -f "$ROOT_DIR/runtime-intent" ]; then
    if service_ok; then
      # Do not take down an interface that another actor has addressed.
      /sbin/ifconfig "$DOWNSTREAM_INTERFACE" > "$ROOT_DIR/downstream-cleanup"
      if /usr/bin/awk -v address="$GATEWAY_ADDRESS" '$1=="inet" && $2!=address{bad=1} $1=="inet6"{bad=1} END{exit bad}' "$ROOT_DIR/downstream-cleanup"; then iface_owned=1; fi
    fi
    if [ "$iface_owned" = 1 ]; then
      /sbin/ifconfig "$DOWNSTREAM_INTERFACE" down || clean=0
      if /sbin/ifconfig "$DOWNSTREAM_INTERFACE" | /usr/bin/awk -v address="$GATEWAY_ADDRESS" '$1=="inet" && $2==address {found=1} END {exit !found}'; then
        /sbin/ifconfig "$DOWNSTREAM_INTERFACE" inet "$GATEWAY_ADDRESS" -alias || clean=0
      fi
      restore_ipv6 || { printf 'ATTENTION: downstream IPv6 baseline could not be restored without attaching or changing unowned state.\n'; clean=0; }
    else
      printf 'ATTENTION: downstream ownership changed; runtime interface cleanup skipped.\n'; clean=0
    fi
  fi
  service_ok && ipv6_ok || clean=0
  [ "$(/usr/sbin/sysctl -n net.inet.ip.forwarding)" = 0 ] || clean=0
  /sbin/ifconfig "$DOWNSTREAM_INTERFACE" > "$ROOT_DIR/downstream-after" || clean=0
  ! /usr/bin/grep -Eq 'flags=.*[<,]UP[,>]|^[[:space:]]+inet6? |IFDISABLED' "$ROOT_DIR/downstream-after" || clean=0
  [ "$(ipv6_interface_mode "$ROOT_DIR/downstream-after")" = "$(/bin/cat "$ROOT_DIR/ipv6-baseline")" ] || clean=0
  if [ -f "$ROOT_DIR/anchor-intent" ]; then
    output=$(pf -a "$ANCHOR" -sn) || clean=0; [ -z "$output" ] || clean=0
    output=$(pf -a "$ANCHOR" -sr) || clean=0; [ -z "$output" ] || clean=0
    output=$(endpoint_states) || clean=0; [ -z "$output" ] || clean=0
  fi
  pf -s References > "$ROOT_DIR/refs-after" || clean=0
  empty_refs "$ROOT_DIR/refs-after" || clean=0
  pf -s info > "$ROOT_DIR/info-after" || clean=0
  /usr/bin/grep -Eq '^Status: Disabled([[:space:]]|$)' "$ROOT_DIR/info-after" || clean=0
  default_hooks && empty_children || clean=0
  /usr/bin/cmp -s "$ROOT_DIR/root-nat-before" "$ROOT_DIR/root-nat-current" || clean=0
  /usr/bin/cmp -s "$ROOT_DIR/root-filter-before" "$ROOT_DIR/root-filter-current" || clean=0
  printf 'runtime_cleanup_ok=%s\nservice=Disabled; expected_forwarding=0; expected_PF=Disabled; expected_downstream=DOWN/no_addresses\n' "$clean"
  [ "$clean" = 1 ]
}
guardian_exit() {
  trap - EXIT HUP INT TERM
  set +e
  local pid= clean=0 changed=0
  [ "$STATE_CLAIMED" = 1 ] || exit "$SERVICE_EXIT"
  [ ! -s "$ROOT_DIR/worker-pid" ] || IFS= read -r pid < "$ROOT_DIR/worker-pid"
  if is_uint "$pid" && [ -s "$ROOT_DIR/worker-pgid" ]; then
    if ! stop_worker "$pid"; then
      status_write ATTENTION 0 'Cannot confirm worker group termination; state retained, no concurrent cleanup.'
      exit 1
    fi
  elif is_uint "$pid" && worker_matches "$pid"; then
    # The armed marker was never published, so this worker cannot mutate.
    /bin/kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  for marker in runtime anchor enable forward; do [ ! -f "$ROOT_DIR/$marker-intent" ] || changed=1; done
  if [ "$changed" = 0 ]; then
    clean=1
    log 'No network mutation was attempted.'
  elif cleanup > "$ROOT_DIR/cleanup.log" 2>&1; then
    clean=1
  fi
  [ ! -f "$ROOT_DIR/cleanup.log" ] || /bin/cat "$ROOT_DIR/cleanup.log"
  if [ "$clean" = 1 ]; then
    status_write STOPPED 1 "Owned resources removed; exit_status=$SERVICE_EXIT"
    if ! archive_state; then status_write ATTENTION 0 'Resources removed but state archive failed; inspect before restart.'; exit 1; fi
  else
    status_write ATTENTION 0 'Cleanup incomplete; root-owned state retained. Automatic ownership takeover is forbidden.'
    log "ATTENTION: recovery state retained at $ROOT_DIR"
    exit 1
  fi
  exit "$SERVICE_EXIT"
}
guardian() {
  [ "$0" = "$INSTALL_SCRIPT" ] || fail 'Start --service only from the root-owned installed path.'
  trap guardian_exit EXIT
  trap 'SERVICE_EXIT=0; exit 0' HUP INT TERM
  claim_state
  local pid pgid own
  printf '%s\n' "$$" > "$ROOT_DIR/guardian-pid"
  status_write STARTING pending 'Checking exclusive ownership of gateway resources.'
  preflight
  write_rules
  set -m
  /bin/bash "$ROOT_DIR/script" --worker "$ROOT_DIR" </dev/null &
  pid=$!
  set +m
  printf '%s\n' "$pid" > "$ROOT_DIR/worker-pid"
  pgid=$(/bin/ps -p "$pid" -o pgid= | compact)
  own=$(/bin/ps -p "$$" -o pgid= | compact)
  [ "$pgid" = "$pid" ] && [ "$pgid" != "$own" ] || fail 'Worker process group was not isolated.'
  printf '%s\n' "$pgid" > "$ROOT_DIR/worker-pgid"
  printf '%s\n' "$$" > "$ROOT_DIR/armed"
  while :; do
    [ ! -e "$ROOT_DIR/worker-stop" ] && worker_matches "$pid" || break
    /bin/sleep 1
  done
  log 'Worker stopped unexpectedly; guardian will clean up before returning failure to launchd.'
  SERVICE_EXIT=1
  return 1
}
worker_exit() {
  local code=$?
  trap '' HUP INT TERM
  printf '%s\n' "$code" > "$ROOT_DIR/worker-exit"
  : > "$ROOT_DIR/worker-stop"
  # Keep the identifiable group leader until guardian stops all descendants.
  while :; do /bin/sleep 1; done
}
worker() {
  private_state "$1"
  set +m
  trap worker_exit EXIT
  trap 'exit 1' HUP INT TERM
  local tries=0 gpid ticks=0
  while [ ! -s "$ROOT_DIR/armed" ]; do
    tries=$((tries+1)); [ "$tries" -le 10 ] || fail 'Guardian did not arm.'
    /bin/sleep 1
  done
  IFS= read -r gpid < "$ROOT_DIR/armed"
  [ "$(/bin/ps -p "$gpid" -o command=)" = "/bin/bash $INSTALL_SCRIPT --service" ] || fail 'Guardian identity changed.'
  [ "$(/bin/ps -p "$$" -o pgid= | compact)" = "$$" ] || fail 'Worker lost its process group.'
  preflight
  intent runtime
  prepare_ipv6 || fail 'Cannot safely establish the downstream IPv6 baseline.'
  intent anchor
  /sbin/pfctl -a "$ANCHOR" -f "$ROOT_DIR/rules" >> "$ROOT_DIR/parse-log" 2>&1
  pf -a "$ANCHOR" -sn > "$ROOT_DIR/loaded-nat"
  pf -a "$ANCHOR" -sr > "$ROOT_DIR/loaded-filter"
  [ "$(/usr/bin/grep -c '^nat ' "$ROOT_DIR/loaded-nat")" = 1 ] || fail 'NAT rule count mismatch.'
  /usr/bin/grep -q 'gateway_upstream' "$ROOT_DIR/loaded-filter" && /usr/bin/grep -q 'gateway_other_egress' "$ROOT_DIR/loaded-filter" || fail 'Egress protection missing.'
  /usr/bin/grep -q 'gateway_dhcp_in' "$ROOT_DIR/loaded-filter" && /usr/bin/grep -q 'gateway_dhcp_no_transit' "$ROOT_DIR/loaded-filter" || fail 'DHCP local-delivery protection missing.'
  default_hooks && empty_children || fail 'PF ownership changed before enable.'
  pf -s References > "$ROOT_DIR/refs-before-enable"
  empty_refs "$ROOT_DIR/refs-before-enable" || fail 'Another PF owner appeared.'
  pf -s info > "$ROOT_DIR/info-before-enable"
  /usr/bin/grep -Eq '^Status: Disabled([[:space:]]|$)' "$ROOT_DIR/info-before-enable" || fail 'PF was enabled concurrently.'
  [ "$(/usr/sbin/sysctl -n net.inet.ip.forwarding)" = 0 ] || fail 'Forwarding changed concurrently.'
  intent enable
  /sbin/pfctl -E > "$ROOT_DIR/enable-output" 2>&1
  sole_owner || fail 'Cannot prove own PF boundary; forwarding remains off.'
  intent alias
  /sbin/ifconfig "$DOWNSTREAM_INTERFACE" inet "$GATEWAY_ADDRESS" netmask 255.255.255.0 alias
  intent up
  /sbin/ifconfig "$DOWNSTREAM_INTERFACE" up
  runtime_owned || fail 'Downstream/PF/IPv6 ownership changed before activation.'
  [ "$(/usr/sbin/sysctl -n net.inet.ip.forwarding)" = 0 ] || fail 'Forwarding changed before activation.'
  intent forward
  /usr/sbin/sysctl -w net.inet.ip.forwarding=1
  [ "$(/usr/sbin/sysctl -n net.inet.ip.forwarding)" = 1 ] || fail 'Could not enable forwarding.'
  status_write RUNNING pending "Gateway active on $DOWNSTREAM_INTERFACE $GATEWAY_ADDRESS through $UPSTREAM_INTERFACE; upstream health is observation only."
  log "RUNNING: $DOWNSTREAM_INTERFACE $GATEWAY_ADDRESS/24, router $CLIENT_ADDRESS, IPv4 forwarding=1, IPv6 forwarding=0."
  while :; do
    runtime_owned || fail 'Service/PF/IPv6/downstream ownership changed.'
    [ "$(/usr/sbin/sysctl -n net.inet.ip.forwarding)" = 1 ] || fail 'Forwarding ownership changed.'
    ticks=$((ticks+1))
    if [ "$((ticks%6))" = 1 ]; then rotate_diagnostics; upstream_observe; fi
    /bin/sleep 5
  done
}
readonly_preflight() {
  local scratch
  # Scratch files only; no state lock, PF load/enable, address or forwarding write.
  scratch=$(/usr/bin/mktemp -d /private/tmp/softrouter-preflight.XXXXXXXX)
  ROOT_DIR=$scratch
  trap '/bin/rm -rf "$ROOT_DIR"' EXIT
  preflight
  write_rules
}
installation_ok
case "${1-}" in
  --service) [ "$#" = 1 ] || fail 'Unexpected arguments.'; guardian ;;
  --worker) [ "$#" = 2 ] || fail 'Unexpected worker arguments.'; worker "$2" ;;
  --preflight) [ "$#" = 1 ] || fail 'Unexpected arguments.'; readonly_preflight ;;
  *) fail 'Usage: /Library/SoftRouter/gateway.sh --service|--preflight' ;;
esac

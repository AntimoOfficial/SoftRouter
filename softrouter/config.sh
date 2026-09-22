#!/bin/bash
# Data-only configuration parser; compatible with macOS Bash 3.2.
# Never source a gateway.conf file or evaluate its values as shell code.
config_error() { printf 'Configuration error: %s\n' "$*" >&2; return 1; }

config_private_ipv4() {
  local value=$1 a b c d part
  local address_pattern='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  local octet_pattern='^(0|[1-9][0-9]{0,2})$'
  [[ "$value" =~ $address_pattern ]] || return 1
  IFS=. read -r a b c d <<< "$value"
  for part in "$a" "$b" "$c" "$d"; do
    [[ "$part" =~ $octet_pattern ]] && [ "$part" -le 255 ] || return 1
  done
  [ "$d" -ge 1 ] && [ "$d" -le 254 ] || return 1
  [ "$a" = 10 ] || { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } ||
    { [ "$a" = 192 ] && [ "$b" = 168 ]; }
}

load_config() {
  local path=$1 line key value seen='|' count=0 first
  local iface_pattern='^en[0-9]{1,3}$'
  local uuid_pattern='^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$'
  local mac_pattern='^([A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}$'
  local service_pattern='^[A-Za-z0-9][A-Za-z0-9 ._()/+-]*$'
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || {
    config_error 'Expected a readable regular configuration file, not a symlink.'; return 1;
  }
  [ "$(/usr/bin/wc -c < "$path")" -le 4096 ] || {
    config_error 'Configuration exceeds 4096 bytes.'; return 1;
  }
  # Reject control bytes before parsing, including NUL which Bash would discard.
  if LC_ALL=C /usr/bin/tr -d '\n' < "$path" | LC_ALL=C /usr/bin/grep -q '[[:cntrl:]]'; then
    config_error 'Control bytes and CRLF are not permitted; save as plain LF text.'; return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) config_error 'Expected KEY=VALUE.'; return 1 ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      UPSTREAM_INTERFACE|DOWNSTREAM_INTERFACE|DOWNSTREAM_SERVICE|DOWNSTREAM_SERVICE_UUID|DOWNSTREAM_MAC|GATEWAY_ADDRESS|CLIENT_ADDRESS) ;;
      *) config_error 'Unknown configuration key.'; return 1 ;;
    esac
    case "$seen" in *"|$key|"*) config_error "Duplicate key: $key"; return 1 ;; esac
    seen="$seen$key|"
    [ -n "$value" ] && [ "${#value}" -le 128 ] || {
      config_error "Empty or overlong value: $key"; return 1;
    }
    case "$key" in
      UPSTREAM_INTERFACE|DOWNSTREAM_INTERFACE)
        [[ "$value" =~ $iface_pattern ]] || { config_error "Invalid Ethernet/Wi-Fi interface: $key"; return 1; } ;;
      DOWNSTREAM_SERVICE)
        [[ "$value" =~ $service_pattern ]] && [ "${value% }" = "$value" ] || {
          config_error 'Service name must use ASCII letters, digits, spaces or ._()/+- without trailing space.'; return 1;
        } ;;
      DOWNSTREAM_SERVICE_UUID)
        [[ "$value" =~ $uuid_pattern ]] || { config_error 'Invalid network service UUID.'; return 1; } ;;
      DOWNSTREAM_MAC)
        [[ "$value" =~ $mac_pattern ]] || { config_error 'Invalid downstream MAC address.'; return 1; }
        first=${value%%:*}
        [ "$((16#$first & 1))" = 0 ] && [ "$value" != 00:00:00:00:00:00 ] || {
          config_error 'Downstream MAC must be a nonzero unicast address.'; return 1;
        }
        value=$(printf '%s' "$value" | /usr/bin/tr 'A-F' 'a-f') ;;
      GATEWAY_ADDRESS|CLIENT_ADDRESS)
        config_private_ipv4 "$value" || { config_error "Expected RFC1918 host address in a /24: $key"; return 1; } ;;
    esac
    # The destination identifier is selected above from a fixed allowlist.
    printf -v "$key" '%s' "$value"
    count=$((count+1))
  done < "$path"
  [ "$count" = 7 ] || { config_error 'All seven configuration keys are required.'; return 1; }
  [ "$UPSTREAM_INTERFACE" != "$DOWNSTREAM_INTERFACE" ] || {
    config_error 'Upstream and downstream must be different interfaces.'; return 1;
  }
  [ "$GATEWAY_ADDRESS" != "$CLIENT_ADDRESS" ] &&
    [ "${GATEWAY_ADDRESS%.*}" = "${CLIENT_ADDRESS%.*}" ] || {
      config_error 'Gateway and client need different host addresses in the same /24.'; return 1;
    }
}

#!/bin/bash
set -eu
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/config.sh"
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/softrouter-config-test.XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT
passed=0
accept() { (load_config "$1") || { printf 'Expected valid: %s\n' "$1" >&2; exit 1; }; passed=$((passed+1)); }
reject() { if (load_config "$1") >/dev/null 2>&1; then printf 'Expected rejection: %s\n' "$1" >&2; exit 1; fi; passed=$((passed+1)); }
change() { /usr/bin/awk -v key="$1" -v value="$2" 'index($0,key "=")==1 {print key "=" value; next} {print}' "$BASE/gateway.conf.example" > "$TMP/case.conf"; }
accept "$BASE/gateway.conf.example"
for entry in '8.8.8.1' '192.168.50.0' '192.168.50.255' '192.168.50.256' '192.168.050.1' '172.15.0.1' '10.0.0.01' '192.168.50.1;false'; do
  change GATEWAY_ADDRESS "$entry"; reject "$TMP/case.conf"
done
change CLIENT_ADDRESS 192.168.51.2; reject "$TMP/case.conf"
change CLIENT_ADDRESS 192.168.50.1; reject "$TMP/case.conf"
change DOWNSTREAM_INTERFACE en0; reject "$TMP/case.conf"
change DOWNSTREAM_INTERFACE 'en1;false'; reject "$TMP/case.conf"
change DOWNSTREAM_SERVICE_UUID 'bad:UUID'; reject "$TMP/case.conf"
change DOWNSTREAM_MAC 01:00:00:00:00:01; reject "$TMP/case.conf"
change DOWNSTREAM_MAC 00:00:00:00:00:00; reject "$TMP/case.conf"
change DOWNSTREAM_MAC AA:BB:CC:DD:EE:FE; accept "$TMP/case.conf"
(load_config "$TMP/case.conf"; [ "$DOWNSTREAM_MAC" = aa:bb:cc:dd:ee:fe ])
change DOWNSTREAM_SERVICE 'USB 10/100/1000 LAN'; accept "$TMP/case.conf"
change DOWNSTREAM_SERVICE 'USB Ethernet '; reject "$TMP/case.conf"
change DOWNSTREAM_SERVICE '$(touch /tmp/softrouter-parser-must-not-execute)'; reject "$TMP/case.conf"
change DOWNSTREAM_SERVICE '`false`'; reject "$TMP/case.conf"
/bin/cp "$BASE/gateway.conf.example" "$TMP/case.conf"
printf '\nCLIENT_ADDRESS=192.168.50.3\n' >> "$TMP/case.conf"; reject "$TMP/case.conf"
/usr/bin/sed '/^DOWNSTREAM_MAC=/d' "$BASE/gateway.conf.example" > "$TMP/case.conf"; reject "$TMP/case.conf"
/bin/cp "$BASE/gateway.conf.example" "$TMP/case.conf"
printf '\nUNKNOWN=value\n' >> "$TMP/case.conf"; reject "$TMP/case.conf"
/usr/bin/sed 's/$/\r/' "$BASE/gateway.conf.example" > "$TMP/case.conf"; reject "$TMP/case.conf"
/bin/cp "$BASE/gateway.conf.example" "$TMP/case.conf"
printf '\000' >> "$TMP/case.conf"; reject "$TMP/case.conf"
/bin/ln -s "$BASE/gateway.conf.example" "$TMP/link.conf"; reject "$TMP/link.conf"
printf 'Configuration tests: %s passed; no network commands executed.\n' "$passed"

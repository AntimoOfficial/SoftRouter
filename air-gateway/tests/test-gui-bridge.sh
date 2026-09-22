#!/bin/bash
set -eu
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/air-gateway-bridge-test.XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT
/bin/bash -n "$BASE/macos/gui-install.sh"
/bin/bash -n "$BASE/tools/build-macos.sh"
# Execute just the pure digest predicate; never invoke privileged setup.
sed -n '/^valid_digest() /p' "$BASE/macos/gui-install.sh" > "$TMP/predicate.sh"
. "$TMP/predicate.sh"
valid_digest ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
for value in '' abc '../file' '$(false)' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; do
  if valid_digest "$value"; then printf 'Unexpected accepted digest\n' >&2; exit 1; fi
done
printf 'GUI bridge checks: 6 passed; no privileged setup invoked.\n'

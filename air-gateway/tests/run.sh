#!/bin/bash
set -eu
set -o pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
for file in gateway.sh gatewayctl config.sh install.sh tests/run.sh tests/test-config.sh tests/test-daemon.sh tools/package.sh; do
  /bin/bash -n "$BASE/$file"
done
/bin/bash "$BASE/tests/test-config.sh"
/bin/bash "$BASE/tests/test-daemon.sh"
/bin/bash "$BASE/tests/test-gui-bridge.sh"
python3 "$BASE/tests/test-publication.py"
python3 "$BASE/tools/check-publication.py"
if [ "$(uname -s)" = Darwin ]; then
  /bin/bash "$BASE/install.sh" --check
fi
printf 'All offline checks passed. No live installation or network mutation was tested.\n'

#!/bin/bash
# Privileged bridge invoked only by the user's explicit graphical install action.
# Freeze and hash the reviewed data; code must come from the root-owned pkg app.
set -eu
set -o pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
fail() { printf 'SoftRouter: %s\n' "$*" >&2; exit 1; }
valid_digest() { [[ "$1" =~ ^[a-f0-9]{64}$ ]]; }
readonly SOURCE='/Applications/SoftRouter.app/Contents/Resources/core'
[ "$(/usr/bin/id -u)" = 0 ] || fail 'Administrator authorization is required.'
[ "$#" = 2 ] || fail 'Expected a configuration file and its reviewed SHA-256.'
valid_digest "$2" || fail 'Invalid configuration digest.'
case "$1" in /*) ;; *) fail 'Configuration path must be absolute.' ;; esac
[ -f "$1" ] && [ ! -L "$1" ] || fail 'Configuration must be a regular file.'
[ "$(/usr/bin/stat -f %z "$1")" -le 4096 ] || fail 'Configuration exceeds 4096 bytes.'
for directory in '/Applications/SoftRouter.app' '/Applications/SoftRouter.app/Contents' '/Applications/SoftRouter.app/Contents/Resources' "$SOURCE" "$SOURCE/diagnostics"; do
  [ -d "$directory" ] && [ ! -L "$directory" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$directory")" = 0:755 ] || fail 'Use the application installed by the official package; its ownership must remain unchanged.'
done
for name in gui-install.sh install.sh gateway.sh gatewayctl config.sh org.softrouter.gateway.plist diagnose.sh diagnostics/lib.sh diagnostics/render.awk; do
  [ -f "$SOURCE/$name" ] && [ ! -L "$SOURCE/$name" ] &&
    [ "$(/usr/bin/stat -f '%u:%Lp:%l' "$SOURCE/$name")" = 0:644:1 ] || fail 'Packaged code ownership or permissions changed.'
done
scratch=$(/usr/bin/mktemp -d /private/tmp/softrouter-gui.XXXXXXXX)
trap '/bin/rm -rf "$scratch"' EXIT
/usr/bin/install -o root -g wheel -m 600 "$1" "$scratch/gateway.conf"
actual=$(/usr/bin/shasum -a 256 "$scratch/gateway.conf" | /usr/bin/awk '{print $1}')
[ "$actual" = "$2" ] || fail 'Configuration changed after review; import it again.'
/bin/bash "$SOURCE/install.sh" --config "$scratch/gateway.conf"

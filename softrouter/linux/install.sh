#!/bin/bash
# Installs application files only. Does not change NetworkManager or enable sharing.
set -eu
set -o pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(uname -s)" = Linux ] || { echo 'Run this installer on Linux.' >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo 'Run: sudo /bin/bash install.sh' >&2; exit 1; }
BASE=$(cd -P "$(dirname "$0")" && pwd)
for command in python3 nmcli ip pkexec; do command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }; done
/usr/bin/python3 -I -c 'import sys, tkinter; assert sys.version_info >= (3, 9)'
[ ! -e /opt/softrouter ] && [ ! -L /opt/softrouter ] || { echo 'Existing /opt/softrouter is preserved. Remove the old app safely before a fresh installation.' >&2; exit 1; }
[ ! -e /usr/share/applications/softrouter.desktop ] && [ ! -L /usr/share/applications/softrouter.desktop ] || { echo 'Existing desktop entry is preserved.' >&2; exit 1; }
[ ! -e /usr/share/pixmaps/softrouter.png ] && [ ! -L /usr/share/pixmaps/softrouter.png ] || { echo 'Existing icon is preserved.' >&2; exit 1; }
/usr/bin/python3 -I - "$BASE" <<'PY'
import os, pathlib, stat, sys
base = pathlib.Path(sys.argv[1])
for name in ('app.py', 'backend.py', 'install.sh', 'uninstall.sh', 'softrouter.desktop', 'config.example.json', 'README.md', 'VERSION', 'LICENSE', 'SoftRouterIcon.png', 'build-info.txt'):
    info = (base / name).lstat()
    if not stat.S_ISREG(info.st_mode):
        raise SystemExit('Release file is missing or not regular: ' + name)
for path in ('/opt', '/usr/share/applications', '/usr/share/pixmaps'):
    info = pathlib.Path(path).lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise SystemExit('Unsafe installation parent: ' + path)
PY
install -d -m 0755 /opt/softrouter
for file in app.py backend.py install.sh uninstall.sh softrouter.desktop config.example.json README.md VERSION LICENSE build-info.txt; do
  install -m 0644 "$BASE/$file" "/opt/softrouter/$file"
done
install -m 0644 "$BASE/softrouter.desktop" /usr/share/applications/softrouter.desktop
install -m 0644 "$BASE/SoftRouterIcon.png" /usr/share/pixmaps/softrouter.png
chown -R root:root /opt/softrouter
/usr/bin/python3 -I /opt/softrouter/backend.py package-end
printf 'Application installed. Open SoftRouter Linux Test. No sharing or system network setting was changed.\n'

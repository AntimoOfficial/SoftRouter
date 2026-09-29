#!/bin/bash
# Refuses uninstall while any owned/recovery journal remains.
set -eu
set -o pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || { echo 'Run this uninstaller as root on Linux.' >&2; exit 1; }
if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S /opt/softrouter/backend.py >/dev/null 2>&1; then
  echo 'This application is package-managed. Disable owned sharing, then run: sudo apt remove softrouter' >&2
  exit 1
fi
/usr/bin/python3 -I /opt/softrouter/backend.py uninstall-check
/usr/bin/python3 -I <<'PY'
import pathlib, stat
root = pathlib.Path('/opt/softrouter')
names = ('app.py', 'backend.py', 'install.sh', 'uninstall.sh', 'softrouter.desktop', 'config.example.json', 'README.md', 'VERSION', 'LICENSE', 'SoftRouterIcon.png', 'build-info.txt')
paths = [root / n for n in names] + [pathlib.Path('/usr/share/applications/softrouter.desktop'), pathlib.Path('/usr/share/pixmaps/softrouter.png')]
for path in paths:
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise SystemExit('Unexpected file preserved: ' + str(path))
for path in paths:
    if path.exists():
        path.unlink()
try:
    root.rmdir()
except OSError:
    print('Extra files remain under /opt/softrouter and were preserved.')
print('App removed. No NetworkManager profile or firewall rule was changed by uninstall.')
PY

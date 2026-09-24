#!/usr/bin/env python3
"""Inspect the installer payload without executing it or installing anything."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

package = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='softrouter-pkg-check-') as temp:
    expanded = pathlib.Path(temp) / 'expanded'
    subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(package), str(expanded)], check=True, stdout=subprocess.DEVNULL)
    infos = list(expanded.rglob('PackageInfo'))
    assert len(infos) == 1, 'Expected one component package'
    info = ET.parse(infos[0]).getroot()
    assert info.get('identifier') == 'org.softrouter.installer'
    assert info.get('install-location') == '/'
    assert info.find('scripts') is None, 'Package scripts are forbidden'
    assert not any(p.name == 'Scripts' for p in expanded.rglob('*')), 'Package must not execute scripts'
    owners = subprocess.check_output(['/usr/bin/lsbom', '-p', 'ug', str(infos[0].parent / 'Bom')], text=True)
    assert owners.strip() and all(line.split() == ['0', '0'] for line in owners.splitlines()), 'Payload must install as root:wheel'
    payload = infos[0].parent / 'Payload'
    app = payload / 'Applications/SoftRouter.app'
    assert app.is_dir()
    for item in payload.rglob('*'):
        assert not item.is_symlink(), 'Payload symlinks are forbidden'
        if item.is_file():
            assert item.is_relative_to(app), 'Unexpected payload outside the app'
            assert not (item.stat().st_mode & 0o022), 'Group/other writable payload'
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert metadata['CFBundleIdentifier'] == 'org.softrouter.setup'
    assert metadata['LSMinimumSystemVersion'] == '14.0'
    core = app / 'Contents/Resources/core'
    assert {p.name for p in core.iterdir()} == {
        'gui-install.sh', 'install.sh', 'gateway.sh', 'gatewayctl', 'config.sh', 'org.softrouter.gateway.plist', 'diagnose.sh', 'diagnostics'
    }, 'Unexpected core payload'
    assert {p.name for p in (core / 'diagnostics').iterdir()} == {'lib.sh', 'render.awk'}
    assert all(p.stat().st_mode & 0o777 == 0o644 for p in core.rglob('*') if p.is_file())
    executable = app / 'Contents/MacOS/SoftRouter'
    architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).split()
    assert set(architectures) == {'arm64', 'x86_64'}, 'Missing universal architecture'
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    subprocess.run([str(executable), '--self-test'], check=True)
    print('Package audit passed: app-only payload, no install scripts, universal binary and ad-hoc integrity verified.')
    print('No Developer ID signature, notarization or live installation was tested.')

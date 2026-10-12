#!/usr/bin/env python3
"""Inspect the installer payload without executing it or installing anything."""
import hashlib
import pathlib
import plistlib
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def app_fingerprint(app):
    app = pathlib.Path(app)
    assert app.is_dir() and not app.is_symlink(), 'Expected an app directory without symlinks'
    digest = hashlib.sha256()
    files = 0
    for item in sorted(app.rglob('*')):
        assert not item.is_symlink(), 'Preview payload symlinks are forbidden'
        if item.is_dir():
            continue
        info = item.stat()
        assert stat.S_ISREG(info.st_mode), 'Preview payload must contain regular files'
        digest.update(item.relative_to(app).as_posix().encode('utf-8') + b'\0')
        digest.update(str(stat.S_IMODE(info.st_mode)).encode('ascii') + b'\0')
        digest.update(str(info.st_size).encode('ascii') + b'\0')
        with item.open('rb') as source:
            for chunk in iter(lambda: source.read(1048576), b''):
                digest.update(chunk)
        files += 1
    assert files, 'Empty app payload'
    return digest.hexdigest()


def verify_preview(app, preview):
    assert app_fingerprint(preview) == app_fingerprint(app), 'Preview does not match the package payload'
    executable = pathlib.Path('Contents/MacOS/SoftRouter')
    expected = hashlib.sha256((app / executable).read_bytes()).hexdigest()
    actual = hashlib.sha256((preview / executable).read_bytes()).hexdigest()
    assert actual == expected, 'Preview executable does not match the package payload'
    return actual


if len(sys.argv) == 3 and sys.argv[1] == '--app-fingerprint':
    print(app_fingerprint(sys.argv[2]))
    sys.exit(0)
if len(sys.argv) not in (2, 3):
    raise SystemExit('Usage: verify-macos.py PACKAGE [PREVIEW_APP]\n       verify-macos.py --app-fingerprint APP')
package = pathlib.Path(sys.argv[1]).resolve()
preview = pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else None
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
    assert metadata['LSMultipleInstancesProhibited'] is True
    assert metadata['CFBundleIconFile'] == 'SoftRouter.icns'
    resources = app / 'Contents/Resources'
    assert (resources / 'SoftRouterIcon.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    icon_bytes = (resources / 'SoftRouter.icns').read_bytes()
    assert icon_bytes[:4] == b'icns' and int.from_bytes(icon_bytes[4:8], 'big') == len(icon_bytes)
    iconset = pathlib.Path(temp) / 'AppIcon.iconset'
    subprocess.run(['/usr/bin/iconutil', '-c', 'iconset', '-o', str(iconset), str(resources / 'SoftRouter.icns')], check=True)
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '' if scale == 1 else '@2x'
            icon = iconset / f'icon_{points}x{points}{suffix}.png'
            data = icon.read_bytes()
            assert data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR'
            assert int.from_bytes(data[16:20], 'big') == points * scale
            assert int.from_bytes(data[20:24], 'big') == points * scale
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
    if preview is not None:
        print('Preview verified against package payload; executable SHA-256: ' + verify_preview(app, preview))
    print('Package audit passed: app-only payload, no install scripts, universal binary and ad-hoc integrity verified.')
    print('No Developer ID signature, notarization or live installation was tested.')

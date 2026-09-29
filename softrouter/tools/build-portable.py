#!/usr/bin/env python3
"""Package reviewed Windows/Linux sources; never install or execute their backends."""
import argparse
import gzip
import hashlib
import io
import pathlib
import re
import subprocess
import sys
import tarfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


def tar_bytes(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for name, (data, mode) in sorted(entries.items()):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = mode
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            info.mtime = 0
            archive.addfile(info, io.BytesIO(data))
    return gzip.compress(stream.getvalue(), mtime=0)


def ar_bytes(entries):
    output = bytearray(b'!<arch>\n')
    for name, data in entries:
        header = f'{name + "/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n'
        assert len(header) == 60
        output.extend(header.encode('ascii'))
        output.extend(data)
        if len(data) % 2:
            output.extend(b'\n')
    return bytes(output)


def build(mode):
    subprocess.run([sys.executable, str(ROOT / 'softrouter/tools/check-publication.py')]
                   + (['--head'] if mode == 'head' else []), check=True)

    def read(name):
        if mode == 'head':
            return subprocess.check_output(['git', '-C', str(ROOT), 'show', 'HEAD:' + name])
        return (ROOT / name).read_bytes()

    names = [n for n in read('PUBLISH_FILES.txt').decode().splitlines() if n and not n.startswith('#')]
    version = read('softrouter/VERSION').decode().strip()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+', version):
        raise ValueError('Unsupported version')
    revision = (subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).decode().strip()
                if mode == 'head' else 'uncommitted-preview')
    info = f'Version: {version}\nSource commit: {revision}\nExperimental: no real Windows/Linux network deployment tested.\n'.encode()
    common = {'LICENSE': (read('LICENSE'), 0o644),
              'VERSION': (read('softrouter/VERSION'), 0o644),
              'SoftRouterIcon.png': (read('softrouter/macos/assets/SoftRouterIcon.png'), 0o644),
              'build-info.txt': (info, 0o644)}
    payloads = {}
    for platform in ('windows', 'linux'):
        prefix = 'softrouter/' + platform + '/'
        files = {n[len(prefix):]: (read(n), 0o755 if n.endswith('.sh') else 0o644)
                 for n in names if n.startswith(prefix) and '/tests/' not in n}
        if not files:
            raise ValueError('Platform source missing: ' + platform)
        files.update(common)
        payloads[platform] = files
    if 'Install.cmd' not in payloads['windows'] or 'install.sh' not in payloads['linux']:
        raise ValueError('Required installer entry is missing')

    out = ROOT / 'dist'
    if out.is_symlink() or (out.exists() and not out.is_dir()):
        raise ValueError('Invalid dist directory')
    out.mkdir(exist_ok=True)
    artifacts = {}
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, (data, permissions) in sorted(payloads['windows'].items()):
            entry = zipfile.ZipInfo('SoftRouter-Windows/' + name)
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = (0o100000 | permissions) << 16
            archive.writestr(entry, data)
    artifacts[f'SoftRouter-{version}-windows-test.zip'] = stream.getvalue()
    artifacts[f'SoftRouter-{version}-linux-test.tar.gz'] = tar_bytes({
        'SoftRouter-Linux/' + n: value for n, value in payloads['linux'].items()})

    # Maintainer scripts only guard replacement/removal; they never enable sharing.
    linux = payloads['linux']
    if 'app.py' not in linux or 'backend.py' not in linux or 'softrouter.desktop' not in linux:
        raise ValueError('Linux desktop payload missing')
    data = {'./opt/softrouter/' + n: value for n, value in linux.items()
            if n not in ('install.sh', 'softrouter.desktop')}
    data['./usr/share/applications/softrouter.desktop'] = linux['softrouter.desktop']
    data['./usr/share/pixmaps/softrouter.png'] = common['SoftRouterIcon.png']
    deb_version = version.replace('-alpha.', '~alpha.')
    control = (f'Package: softrouter\nVersion: {deb_version}\nArchitecture: all\n'
               'Maintainer: SoftRouter contributors\nSection: net\nPriority: optional\n'
               'Depends: python3 (>= 3.9), python3-tk, network-manager, policykit-1, iproute2, dnsmasq-base\n'
               'Homepage: https://github.com/AntimoOfficial/SoftRouter\n'
               'Description: Experimental Wi-Fi to Ethernet sharing assistant\n'
               ' Uses NetworkManager; installing the app does not enable sharing.\n').encode()
    preinst = b'''#!/bin/sh
set -eu
case "${1:-}" in
  install)
    if [ -e /opt/softrouter ] || [ -L /opt/softrouter ]; then
      echo 'Existing /opt/softrouter preserved. Remove that installation safely first.' >&2
      exit 1
    fi
    ;;
esac
if [ -e /var/lib/softrouter/ownership.json ] || [ -L /var/lib/softrouter/ownership.json ]; then
  echo 'Disable or recover existing SoftRouter sharing before installation or upgrade.' >&2
  exit 1
fi
'''
    prerm = b'''#!/bin/sh
set -eu
case "${1:-}" in
  remove|deconfigure|upgrade)
    /usr/bin/python3 -I /opt/softrouter/backend.py uninstall-check
    ;;
esac
'''
    artifacts[f'SoftRouter-{version}-linux-test_all.deb'] = ar_bytes([
        ('debian-binary', b'2.0\n'),
        ('control.tar.gz', tar_bytes({'./control': (control, 0o644),
                                      './preinst': (preinst, 0o755), './prerm': (prerm, 0o755)})),
        ('data.tar.gz', tar_bytes(data))])
    for name in artifacts:
        if (out / name).exists() or (out / name).is_symlink():
            raise ValueError('Output already exists: ' + name)
    for name, data in artifacts.items():
        with (out / name).open('xb') as file:
            file.write(data)
        (out / (name + '.sha256')).write_text(hashlib.sha256(data).hexdigest() + '  ' + name + '\n')
        print(out / name)
    print('Packaged source-based apps and installers; no Windows/Linux live network testing.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--head', action='store_true')
    group.add_argument('--worktree', action='store_true')
    args = parser.parse_args()
    build('worktree' if args.worktree else 'head')

#!/usr/bin/env python3
"""Validate an explicit publication manifest against disk, the index, or HEAD."""
import argparse
import fnmatch
import hashlib
import pathlib
import re
import struct
import subprocess
import sys
import zlib

ICON_PATH = 'softrouter/macos/assets/SoftRouterIcon.png'
PNG_LIMIT = 16 * 1024 * 1024
# Exact reviewed C2PA body for ICON_PATH only; new provenance needs explicit review.
ICON_PROVENANCE_SHA256 = frozenset({
    'f96062903499119f5dcc9458e45670349d3db4d313083573fb05ffcc1bd6a900',
})

ROOT_FILES = {
    '.gitignore', 'README.md', 'AGENTS.md', 'LICENSE', 'CONTRIBUTING.md',
    'SECURITY.md', 'PUBLISH_FILES.txt',
}
FORBIDDEN = (
    '.env*', 'gateway.conf', '*.local.conf', '*.log', '*.pcap*', '*.key',
    '*.pem', '*.p12', '*.sqlite*', '*.db', 'authorized_keys', 'known_hosts',
    'id_rsa*', 'id_ed25519*', '.DS_Store', '*.pyc',
)
BAD_DIRS = {'logs', 'runtime', 'dist', '__pycache__', '.git', 'node_modules'}
PATTERNS = (
    ('private key', re.compile(rb'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----')),
    ('GitHub token', re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})')),
    ('SSH authorization', re.compile(rb'ssh-(?:ed25519|rsa) [A-Za-z0-9+/]{30,}')),
    ('personal home path', re.compile(rb'/Users/(?!Shared(?:/|\b)|example(?:/|\b))[A-Za-z0-9_.-]+/')),
    ('credential-bearing URL', re.compile(rb'https?://[^\s/@:]+:[^\s/@]+@')),
)


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.PIPE)


def check_path(name):
    path = pathlib.PurePosixPath(name)
    if (not name or path.is_absolute() or '..' in path.parts or str(path) != name
            or '\\' in name or any(ord(c) < 33 for c in name)):
        raise ValueError('Invalid publication path')
    if name not in ROOT_FILES and not name.startswith(('softrouter/', '.github/')):
        raise ValueError('Outside public partition: ' + name)
    if any(p in BAD_DIRS or p.startswith(('recovery', 'softrouter-report-')) for p in path.parts):
        raise ValueError('Private/generated directory: ' + name)
    if any(fnmatch.fnmatchcase(path.name, pat) for pat in FORBIDDEN):
        raise ValueError('Private/generated filename: ' + name)


def validate_icon_png(data):
    """Accept one bounded, noninterlaced RGB/RGBA icon without text metadata."""
    def invalid():
        raise ValueError('Invalid or unsupported public icon PNG')

    if len(data) > PNG_LIMIT or not data.startswith(b'\x89PNG\r\n\x1a\n'):
        invalid()
    offset = 8
    width = height = channels = None
    seen = set()
    pixel_chunks = []
    pixels_started = False
    pixels_finished = False
    ended = False
    metadata_lengths = {b'sRGB': 1, b'gAMA': 4, b'pHYs': 9, b'cHRM': 32}
    while offset < len(data):
        if len(data) - offset < 12:
            invalid()
        length = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + length + 12
        if length > PNG_LIMIT or end > len(data):
            invalid()
        payload = data[offset + 8:end - 4]
        checksum = struct.unpack_from('>I', data, end - 4)[0]
        if zlib.crc32(kind + payload) & 0xffffffff != checksum:
            invalid()
        if offset == 8 and kind != b'IHDR':
            invalid()
        if kind == b'IHDR':
            if kind in seen or offset != 8 or length != 13:
                invalid()
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            if (width != height or not 1024 <= width <= 4096 or depth != 8
                    or color not in (2, 6) or compression != 0 or filtering != 0 or interlace != 0):
                invalid()
            channels = 3 if color == 2 else 4
        elif kind == b'IDAT':
            if pixels_finished:
                invalid()
            pixels_started = True
            pixel_chunks.append(payload)
        elif kind == b'IEND':
            if length != 0 or not pixels_started or end != len(data):
                invalid()
            ended = True
        elif kind == b'caBX':
            if (kind in seen or pixels_started or not 0 < length <= 65536
                    or hashlib.sha256(payload).hexdigest() not in ICON_PROVENANCE_SHA256):
                invalid()
        elif kind in metadata_lengths:
            if kind in seen or pixels_started or length != metadata_lengths[kind]:
                invalid()
            if kind == b'sRGB' and payload[0] > 3:
                invalid()
            if kind == b'gAMA' and struct.unpack('>I', payload)[0] == 0:
                invalid()
            if kind == b'pHYs' and payload[8] not in (0, 1):
                invalid()
        else:
            # No EXIF, comments, embedded profiles, palettes, animation or unknown chunks.
            invalid()
        if pixels_started and kind != b'IDAT':
            pixels_finished = True
        seen.add(kind)
        offset = end
    if not ended:
        invalid()
    stride = 1 + width * channels
    expected = height * stride
    try:
        decoder = zlib.decompressobj()
        pixels = decoder.decompress(b''.join(pixel_chunks), expected + 1)
    except zlib.error:
        invalid()
    if (len(pixels) != expected or not decoder.eof
            or decoder.unused_data or decoder.unconsumed_tail):
        invalid()
    if any(pixels[row] > 4 for row in range(0, expected, stride)):
        invalid()


def validate(root, mode):
    root = root.resolve()
    entries = {}
    if mode == 'staged':
        for entry in git(root, 'ls-files', '--stage', '-z').split(b'\0'):
            if not entry:
                continue
            metadata, path = entry.split(b'\t', 1)
            filemode, _oid, stage = metadata.decode().split()
            if stage != '0':
                raise ValueError('Unmerged index')
            entries[path.decode('utf-8')] = filemode
    elif mode == 'head':
        for entry in git(root, 'ls-tree', '-rz', 'HEAD').split(b'\0'):
            if not entry:
                continue
            metadata, path = entry.split(b'\t', 1)
            filemode, kind, _oid = metadata.decode().split()
            if kind != 'blob':
                raise ValueError('Submodule or unsupported Git object')
            entries[path.decode('utf-8')] = filemode

    def read(name):
        if mode == 'staged':
            return git(root, 'show', ':' + name)
        if mode == 'head':
            return git(root, 'show', 'HEAD:' + name)
        path = root / name
        # Reject symlinks in every component, including internal symlinks.
        current = root
        for component in pathlib.PurePosixPath(name).parts:
            current = current / component
            if current.is_symlink():
                raise ValueError('Symlink in publication path: ' + name)
        if not path.is_file():
            raise ValueError('Missing regular file: ' + name)
        return path.read_bytes()

    manifest = read('PUBLISH_FILES.txt').decode('utf-8')
    names = [line.strip() for line in manifest.splitlines() if line.strip() and not line.startswith('#')]
    if len(names) != len(set(names)) or 'PUBLISH_FILES.txt' not in names:
        raise ValueError('Duplicate manifest entries or missing manifest itself')
    for name in names:
        check_path(name)
    if mode != 'worktree':
        extra = sorted(set(entries) - set(names))
        missing = sorted(set(names) - set(entries))
        if extra or missing:
            raise ValueError('Manifest mismatch; extra=' + repr(extra) + '; missing=' + repr(missing))
        for name, filemode in entries.items():
            if filemode not in ('100644', '100755'):
                raise ValueError('Non-regular Git file: ' + name)
    for name in names:
        data = read(name)
        if name == ICON_PATH:
            validate_icon_png(data)
        else:
            if len(data) > 1024 * 1024 or b'\0' in data:
                raise ValueError('Binary or oversized release input: ' + name)
            data.decode('utf-8')
        for description, pattern in PATTERNS:
            if pattern.search(data):
                # Never print the matched value.
                raise ValueError(description + ' detected in ' + name)
    return len(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[2])
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--staged', action='store_true', help='Check actual index contents and complete file list')
    group.add_argument('--head', action='store_true', help='Check committed contents and complete file list')
    args = parser.parse_args()
    mode = 'staged' if args.staged else 'head' if args.head else 'worktree'
    try:
        count = validate(args.root, mode)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Git command output may contain private material; do not include it.
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        print('Publication check FAILED: ' + reason, file=sys.stderr)
        return 1
    print('Publication check passed: {} public files checked ({})'.format(count, mode))
    print('Allowlist and pattern checks do not replace manual content review.')
    return 0


if __name__ == '__main__':
    sys.exit(main())

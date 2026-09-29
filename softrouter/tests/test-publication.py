#!/usr/bin/env python3
"""Synthetic publication fixtures; no personal workspace inputs."""
import importlib.util
import hashlib
import pathlib
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import zlib

SPEC = importlib.util.spec_from_file_location('publication', pathlib.Path(__file__).resolve().parents[1] / 'tools/check-publication.py')
publication = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publication)


def png_chunk(kind, payload=b''):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)


def icon_png(width=1024, height=1024, color=6, depth=8, interlace=0, metadata=(), compressed=None):
    header = struct.pack('>IIBBBBB', width, height, depth, color, 0, 0, interlace)
    if compressed is None:
        compressed = zlib.compress(bytes(height * (1 + width * (3 if color == 2 else 4))))
    return (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', header)
            + b''.join(png_chunk(kind, value) for kind, value in metadata)
            + png_chunk(b'IDAT', compressed) + png_chunk(b'IEND'))


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        (self.root / 'PUBLISH_FILES.txt').write_text('PUBLISH_FILES.txt\nREADME.md\n')
        (self.root / 'README.md').write_text('Public example\n')

    def test_valid(self):
        self.assertEqual(publication.validate(self.root, 'worktree'), 2)

    def test_private_partition(self):
        with (self.root / 'PUBLISH_FILES.txt').open('a') as stream:
            stream.write('private/report.md\n')
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'worktree')

    def test_symlink(self):
        (self.root / 'README.md').unlink()
        (self.root / 'README.md').symlink_to(self.root / 'PUBLISH_FILES.txt')
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'worktree')

    def test_secret(self):
        (self.root / 'README.md').write_text('-----BEGIN ' + 'OPENSSH PRIVATE KEY-----\n')
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'worktree')

    def test_local_config(self):
        with self.assertRaises(ValueError):
            publication.check_path('softrouter/gateway.conf')

    def test_diagnostic_report_is_private(self):
        with self.assertRaises(ValueError):
            publication.check_path('softrouter/softrouter-report-example/report.json')

    def test_parent_traversal(self):
        with self.assertRaises(ValueError):
            publication.check_path('softrouter/../private.md')

    def add_icon(self, data, name=publication.ICON_PATH):
        with (self.root / 'PUBLISH_FILES.txt').open('a') as stream:
            stream.write(name + '\n')
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_public_icon_rgb_and_rgba(self):
        path = self.add_icon(icon_png())
        self.assertEqual(publication.validate(self.root, 'worktree'), 3)
        path.write_bytes(icon_png(color=2, metadata=(
            (b'sRGB', b'\0'), (b'gAMA', struct.pack('>I', 45455)),
            (b'pHYs', struct.pack('>IIB', 2835, 2835, 1)), (b'cHRM', bytes(32)),
        )))
        self.assertEqual(publication.validate(self.root, 'worktree'), 3)

    def test_icon_exception_has_exact_path(self):
        self.add_icon(icon_png(), 'softrouter/macos/assets/Other.png')
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'worktree')

    def test_other_binary_still_rejected(self):
        self.add_icon(b'icns\0\0\0\x08', 'softrouter/macos/assets/SoftRouterIcon.icns')
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'worktree')

    def test_text_size_limit_unchanged(self):
        (self.root / 'README.md').write_bytes(b'a' * (1024 * 1024 + 1))
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'worktree')

    def test_icon_requires_png_signature(self):
        with self.assertRaises(ValueError):
            publication.validate_icon_png(b'Public example\n')

    def test_icon_rejects_metadata_and_unknown_chunks(self):
        for kind in (b'tEXt', b'zTXt', b'iTXt', b'eXIf', b'iCCP', b'PLTE', b'acTL', b'zzZZ'):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                publication.validate_icon_png(icon_png(metadata=((kind, b'private fixture'),)))

    def test_icon_rejects_invalid_fixed_metadata(self):
        for kind, value in ((b'sRGB', b'\x04'), (b'gAMA', bytes(4)),
                            (b'pHYs', bytes(8) + b'\x02'), (b'cHRM', bytes(31))):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                publication.validate_icon_png(icon_png(metadata=((kind, value),)))
        with self.assertRaises(ValueError):
            publication.validate_icon_png(icon_png(metadata=((b'sRGB', b'\0'), (b'sRGB', b'\0'))))

    def test_icon_provenance_requires_exact_reviewed_hash(self):
        provenance = b'Synthetic reviewed provenance fixture'
        approved = {hashlib.sha256(provenance).hexdigest()}
        with self.assertRaises(ValueError):
            publication.validate_icon_png(icon_png(metadata=((b'caBX', provenance),)))
        with mock.patch.object(publication, 'ICON_PROVENANCE_SHA256', approved):
            publication.validate_icon_png(icon_png(metadata=((b'caBX', provenance),)))
            with self.assertRaises(ValueError):
                publication.validate_icon_png(icon_png(metadata=((b'caBX', provenance + b'changed'),)))
            with self.assertRaises(ValueError):
                publication.validate_icon_png(icon_png(metadata=((b'caBX', provenance), (b'caBX', provenance))))
            data = icon_png()
            with self.assertRaises(ValueError):
                publication.validate_icon_png(data[:-12] + png_chunk(b'caBX', provenance) + png_chunk(b'IEND'))
        for provenance in (b'', bytes(65537)):
            with mock.patch.object(publication, 'ICON_PROVENANCE_SHA256', {hashlib.sha256(provenance).hexdigest()}):
                with self.assertRaises(ValueError):
                    publication.validate_icon_png(icon_png(metadata=((b'caBX', provenance),)))

    def test_reviewed_icon_provenance_still_runs_secret_patterns(self):
        provenance = b'-----BEGIN ' + b'OPENSSH PRIVATE KEY-----'
        self.add_icon(icon_png(metadata=((b'caBX', provenance),)))
        with mock.patch.object(publication, 'ICON_PROVENANCE_SHA256', {hashlib.sha256(provenance).hexdigest()}):
            with self.assertRaisesRegex(ValueError, 'private key detected'):
                publication.validate(self.root, 'worktree')

    def test_icon_rejects_crc_corruption(self):
        data = bytearray(icon_png())
        data[-1] ^= 1
        with self.assertRaises(ValueError):
            publication.validate_icon_png(bytes(data))

    def test_icon_rejects_wrong_dimensions_and_encoding(self):
        cases = ({'width': 1023}, {'width': 4097, 'height': 4097}, {'height': 1025},
                 {'depth': 16}, {'color': 3}, {'interlace': 1})
        for args in cases:
            with self.subTest(args=args), self.assertRaises(ValueError):
                publication.validate_icon_png(icon_png(compressed=zlib.compress(b''), **args))

    def test_icon_rejects_trailing_and_truncated_data(self):
        data = icon_png()
        for broken in (data + b'private fixture', data[:-1], data[:-12], data[:10]):
            with self.subTest(size=len(broken)), self.assertRaises(ValueError):
                publication.validate_icon_png(broken)

    def test_icon_rejects_chunk_length_overrun(self):
        data = icon_png()
        with self.assertRaises(ValueError):
            publication.validate_icon_png(data[:8] + struct.pack('>I', 0xffffffff) + data[12:])

    def test_icon_rejects_total_size_over_limit(self):
        with self.assertRaises(ValueError):
            publication.validate_icon_png(b'\x89PNG\r\n\x1a\n' + bytes(publication.PNG_LIMIT))

    def test_icon_checks_compressed_pixel_stream(self):
        raw = bytes(1024 * (1 + 1024 * 4))
        cases = (b'not zlib', zlib.compress(raw[:-1]), zlib.compress(raw + b'\0'),
                 zlib.compress(raw) + b'trailing', zlib.compress(raw)[:-1],
                 zlib.compress(b'\x05' + raw[1:]))
        for compressed in cases:
            with self.subTest(size=len(compressed)), self.assertRaises(ValueError):
                publication.validate_icon_png(icon_png(compressed=compressed))

    def test_icon_accepts_contiguous_pixel_chunks(self):
        data = icon_png()
        offset = 8 + 25  # PNG signature plus IHDR.
        length = struct.unpack_from('>I', data, offset)[0]
        pixels = data[offset + 8:offset + 8 + length]
        split = len(pixels) // 2
        publication.validate_icon_png(data[:offset] + png_chunk(b'IDAT', pixels[:split])
                                      + png_chunk(b'IDAT', pixels[split:]) + png_chunk(b'IEND'))

    def test_icon_rejects_bad_chunk_order(self):
        data = icon_png()
        ihdr, rest = data[8:33], data[33:]
        cases = (data[:8] + png_chunk(b'sRGB', b'\0') + ihdr + rest,
                 data[:33] + ihdr + rest,
                 data[:-12] + png_chunk(b'sRGB', b'\0') + png_chunk(b'IEND'),
                 data[:33] + png_chunk(b'IEND'))
        for broken in cases:
            with self.subTest(size=len(broken)), self.assertRaises(ValueError):
                publication.validate_icon_png(broken)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.PIPE)

    def test_index_checks_staged_bytes(self):
        self.git('init', '-q')
        self.git('add', 'PUBLISH_FILES.txt', 'README.md')
        (self.root / 'README.md').write_text('-----BEGIN ' + 'OPENSSH PRIVATE KEY-----\n')
        self.assertEqual(publication.validate(self.root, 'staged'), 2)
        self.git('add', 'README.md')
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'staged')

    def test_icon_index_and_head_check_exact_bytes(self):
        path = self.add_icon(icon_png())
        self.git('init', '-q')
        self.git('add', 'PUBLISH_FILES.txt', 'README.md', publication.ICON_PATH)
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com',
                 'commit', '-qm', 'Synthetic icon fixture')
        path.write_bytes(icon_png(metadata=((b'tEXt', b'private fixture'),)))
        self.assertEqual(publication.validate(self.root, 'staged'), 3)
        self.assertEqual(publication.validate(self.root, 'head'), 3)
        self.git('add', publication.ICON_PATH)
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'staged')
        self.assertEqual(publication.validate(self.root, 'head'), 3)
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com',
                 'commit', '-qm', 'Synthetic invalid icon fixture')
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'head')

    def test_forced_private_add(self):
        self.git('init', '-q')
        self.git('add', 'PUBLISH_FILES.txt', 'README.md')
        (self.root / 'private.md').write_text('Not for publication\n')
        self.git('add', 'private.md')
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'staged')


if __name__ == '__main__':
    unittest.main()

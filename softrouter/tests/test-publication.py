#!/usr/bin/env python3
"""Synthetic publication fixtures; no personal workspace inputs."""
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('publication', pathlib.Path(__file__).resolve().parents[1] / 'tools/check-publication.py')
publication = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publication)


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

    def test_parent_traversal(self):
        with self.assertRaises(ValueError):
            publication.check_path('softrouter/../private.md')

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

    def test_forced_private_add(self):
        self.git('init', '-q')
        self.git('add', 'PUBLISH_FILES.txt', 'README.md')
        (self.root / 'private.md').write_text('Not for publication\n')
        self.git('add', 'private.md')
        with self.assertRaises(ValueError):
            publication.validate(self.root, 'staged')


if __name__ == '__main__':
    unittest.main()

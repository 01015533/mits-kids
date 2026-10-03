import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release import local_signing_password


class LocalSigningPasswordTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'private.txt'
        self.value = 'public-test-fixture-password-never-an-actual-key'
        self.path.write_text(self.value + '\n')
        self.path.chmod(0o600)

    def test_owner_private_single_password(self):
        self.assertEqual(local_signing_password(self.path), self.value)

    def test_world_readable_password_is_rejected(self):
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            local_signing_password(self.path)

    def test_symlink_and_multiline_are_rejected(self):
        link = self.path.with_name('link.txt')
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            local_signing_password(link)
        self.path.write_text(self.value + '\nsecond value')
        with self.assertRaises(ValueError):
            local_signing_password(self.path)

    def test_new_signer_refuses_existing_directory(self):
        from create_app_signer import create
        with self.assertRaises(FileExistsError):
            create(Path(self.directory.name), '/not/invoked')
        self.assertEqual(self.path.read_text(), self.value + '\n')


if __name__ == '__main__':
    unittest.main()

import hashlib
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from source_snapshot import snapshot  # noqa: E402


class SourceSnapshotTests(unittest.TestCase):
    def test_wrapper_inputs_and_permissions_are_preserved_without_expanding_jar_scope(self):
        with tempfile.TemporaryDirectory(prefix='mits-source-snapshot-', dir='/tmp') as temporary:
            root = Path(temporary) / 'project'
            expected = {
                'pubspec.yaml': b'name: fixture\nversion: 0.4.0+4\n',
                'lib/main.dart': b'void main() {}\n',
                'android/gradlew': b'#!/bin/sh\nexec java -cp "$0.jar" org.gradle.wrapper.GradleWrapperMain "$@"\n',
                'android/gradlew.bat': b'@echo off\r\n',
                'android/gradle/wrapper/gradle-wrapper.jar': b'wrapper fixture bytes',
                'android/gradle/wrapper/gradle-wrapper.properties': b'distributionUrl=https\\://services.gradle.org/distributions/gradle-9.1-bin.zip\n',
                'tools/Signer.java': b'class Signer {}\n',
            }
            excluded = {
                'android/local.properties', 'android/key.properties',
                'android/private.jks', 'android/private.p12',
                'android/gradle/wrapper/other.jar', 'android/app/build/generated/Secret.java',
                'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
                'android/.gradle/state.json', 'tools/__pycache__/cached.py',
            }
            for name, value in expected.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value)
            for name in excluded:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('must not be archived')
            (root / 'android/gradlew').chmod(0o755)
            output = Path(temporary) / 'evidence'
            snapshot(root, output)
            records = json.loads((output / 'source-manifest.json').read_text())
            self.assertEqual(set(records), set(expected))
            with tarfile.open(output / 'source.tar.gz') as archive:
                self.assertEqual(set(archive.getnames()), set(expected))
                for name, value in expected.items():
                    actual = archive.extractfile(name).read()
                    self.assertEqual(actual, value)
                    self.assertEqual(records[name], hashlib.sha256(actual).hexdigest())
                self.assertEqual(archive.getmember('android/gradlew').mode & 0o111, 0o111)

    def test_allowlisted_files_and_parent_directories_cannot_follow_symlinks(self):
        with tempfile.TemporaryDirectory(prefix='mits-source-links-', dir='/tmp') as temporary:
            root = Path(temporary) / 'project'
            (root / 'android/gradle').mkdir(parents=True)
            private = Path(temporary) / 'private'
            private.mkdir()
            (private / 'gradle-wrapper.jar').write_text('external private bytes')
            (private / 'source.java').write_text('external private bytes')
            (root / 'pubspec.yaml').symlink_to(private / 'source.java')
            (root / 'android/gradlew').symlink_to(private / 'source.java')
            (root / 'android/gradle/wrapper').symlink_to(private, target_is_directory=True)
            (root / 'tools').symlink_to(private, target_is_directory=True)
            output = Path(temporary) / 'evidence'
            snapshot(root, output)
            self.assertEqual(json.loads((output / 'source-manifest.json').read_text()), {})
            with tarfile.open(output / 'source.tar.gz') as archive:
                self.assertEqual(archive.getnames(), [])


if __name__ == '__main__':
    unittest.main()

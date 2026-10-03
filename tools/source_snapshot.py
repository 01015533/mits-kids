#!/usr/bin/env python3
"""Record a source-only snapshot, excluding caches, backups and signing material."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile

ROOT_FILES = {'pubspec.yaml', 'pubspec.lock', 'README.md', 'analysis_options.yaml', '.gitignore', '.metadata'}
BUILD_BOOTSTRAP_FILES = {
    'android/gradlew',
    'android/gradlew.bat',
    'android/gradle/wrapper/gradle-wrapper.jar',
}
SOURCE_DIRS = ('lib', 'test', 'integration_test', 'android', 'tools', 'docs')
SUFFIXES = {'.dart', '.kt', '.kts', '.gradle', '.java', '.py', '.sh', '.xml', '.md', '.yaml', '.json', '.properties', '.png'}
EXCLUDED_DIRS = {'.gradle', 'build', '__pycache__', '.dart_tool'}
GENERATED_FILES = {
    'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
}


def source_files(root):
    root = root.resolve()

    def safe_file(path):
        relative = path.relative_to(root)
        if (EXCLUDED_DIRS.intersection(relative.parts) or relative.as_posix() in GENERATED_FILES
                or not path.is_file()):
            return False
        # Also reject a root allowlisted file or directory symlink: a wrapper
        # path must never pull an external keystore or other private data in.
        candidate = root
        for part in relative.parts:
            candidate = candidate / part
            if candidate.is_symlink():
                return False
        return path.resolve().is_relative_to(root)

    files = [root / name for name in ROOT_FILES if safe_file(root / name)]
    for name in SOURCE_DIRS:
        for path in (root / name).rglob('*'):
            relative = path.relative_to(root)
            if not safe_file(path):
                continue
            if path.name in {'local.properties', 'key.properties'}:
                continue
            if path.suffix not in SUFFIXES and relative.as_posix() not in BUILD_BOOTSTRAP_FILES:
                continue
            files.append(path)
    return sorted(files)


def snapshot(root, destination):
    root = root.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    files = source_files(root)
    records = {}
    with tarfile.open(destination / 'source.tar.gz', 'w:gz') as archive:
        for path in files:
            name = path.relative_to(root).as_posix()
            info = archive.gettarinfo(str(path), arcname=name)
            if not info.isfile():
                raise ValueError('A source input stopped being a regular file.')
            data = path.read_bytes()
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
            # Hash exactly the bytes stored, even if a source file changes
            # between the filesystem scan and archive creation.
            records[name] = hashlib.sha256(data).hexdigest()
    manifest = (json.dumps(records, sort_keys=True, indent=2) + '\n').encode()
    (destination / 'source-manifest.json').write_bytes(manifest)
    digest = hashlib.sha256(manifest).hexdigest()
    (destination / 'source-manifest.sha256').write_text(digest + '  source-manifest.json\n')
    return digest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(snapshot(Path(__file__).resolve().parent.parent, args.destination.resolve()))

#!/usr/bin/env python3
"""Compile and run pure JVM security checks with installed/cached Kotlin tools."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile


def run():
    root = Path(__file__).resolve().parent.parent
    native = root / 'android/app/src/main/kotlin/com/mitskids/offline'
    tests = root / 'tools/tests/native'
    sources = [native / name for name in (
        'PinDerivation.kt', 'RetryDelay.kt', 'OfflineStoragePaths.kt',
        'CredentialEpoch.kt', 'ParentAuthority.kt', 'BackupManifest.kt', 'BackupCodec.kt',
        'PlaybackKeyLock.kt', 'ScreenOffRecoveryPolicy.kt', 'PlayerLockScreenVisibility.kt',
        'SeekPreviewPolicy.kt', 'PlaybackImmersivePolicy.kt',
    ) if (native / name).exists()] + sorted(tests.glob('*.kt'))
    with tempfile.TemporaryDirectory(prefix='mits-native-') as work:
        jar = Path(work) / 'checks.jar'
        compiler = shutil.which('kotlinc')
        if compiler:
            cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
            dependencies = []
            for group, artifact, version in (
                ('com.google.crypto.tink', 'tink-android', '1.23.0'),
                ('com.google.code.gson', 'gson', '2.13.2'),
            ):
                resolved = sorted((cache / group / artifact / version).glob('*/*.jar'))
                if not resolved:
                    raise SystemExit(f'Build Android once to resolve {group}:{artifact}:{version}.')
                dependencies += resolved
            classpath = os.pathsep.join(map(str, dependencies))
            subprocess.run([compiler, *map(str, sources), '-classpath', classpath, '-jvm-target', '17', '-include-runtime', '-d', str(jar)], check=True)
            runtime = str(jar) + os.pathsep + classpath
        else:
            cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
            jars = []
            for group, artifact, version in (
                ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.0'),
                ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.0'),
                ('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.4.0'),
                ('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
                ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
                ('org.jetbrains', 'annotations', '13.0'),
                ('com.google.crypto.tink', 'tink-android', '1.23.0'),
                ('com.google.code.gson', 'gson', '2.13.2'),
            ):
                jars += sorted((cache / group / artifact / version).glob('*/*.jar'))
            if not any(p.name.startswith('kotlin-compiler-embeddable-') for p in jars):
                raise SystemExit('Install kotlinc or build Android once to populate the pinned Kotlin compiler cache.')
            classpath = os.pathsep.join(map(str, jars))
            subprocess.run([
                'java', '-cp', classpath, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', classpath,
                *map(str, sources), '-d', str(jar),
            ], check=True)
            runtime = str(jar) + os.pathsep + classpath
        for test in sorted(tests.glob('*.kt')):
            subprocess.run(['java', '-cp', runtime, 'com.mitskids.offline.' + test.stem + 'Kt'], check=True)


if __name__ == '__main__':
    run()

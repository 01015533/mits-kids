#!/usr/bin/env python3
"""Build and record a signed release; enter passwords only in a local terminal."""
import argparse
from datetime import datetime, timezone
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

from source_snapshot import snapshot


def local_signing_password(path):
    """Read only an owner-private local credential, never print its contents."""
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Signing password file must be a regular file owned by this user with mode 600 or stricter.')
    if info.st_size > 4096:
        raise ValueError('Signing password file is unexpectedly large.')
    value = path.read_text().rstrip('\r\n')
    if len(value) < 16 or '\n' in value or '\r' in value:
        raise ValueError('Signing password file must contain one strong password.')
    return value


def artifact_record(path):
    return {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'bytes': path.stat().st_size}


def build_manifest(output, report, signing_description):
    """The signed document covers immutable build evidence, never runtime approval."""
    excluded = {'release.json', 'RELEASE-NOTES.md', 'build-manifest.json',
                'build-manifest.sig', 'manifest-sign.txt', 'manifest-verify.txt'}
    artifacts = {path.name: artifact_record(path) for path in sorted(output.iterdir())
                 if path.is_file() and not path.is_symlink() and path.name not in excluded}
    return {
        'schema': 'mits-kids-build-manifest-v1',
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'application_id': report['application_id'],
        'version_name': report['version_name'],
        'version_code': report['version_code'],
        'abis': report['abis'],
        'apk_sha256': report['apk_sha256'],
        'source_manifest_sha256': report['source_manifest_sha256'],
        'lockfile_sha256': report['lockfile_sha256'],
        'signing': signing_description,
        'artifacts': artifacts,
        'scope': 'Build artifacts and recorded automated checks only. Runtime and tablet acceptance are separate.',
    }


def verify_build_manifest(output, expected_signer, java):
    """Public-only verification pins an independently trusted app certificate."""
    tool = Path(__file__).with_name('SignReleaseManifest.java')
    clean_env = os.environ.copy()
    for name in ('MITS_RELEASE_STORE_PASSWORD', 'MITS_RELEASE_KEY_PASSWORD'):
        clean_env.pop(name, None)
    subprocess.run([str(java), str(tool), 'verify', str(output / 'build-manifest.json'),
                    str(output / 'signing-certificate.der'), str(output / 'build-manifest.sig'),
                    expected_signer], env=clean_env, check=True)
    manifest = json.loads((output / 'build-manifest.json').read_text())
    if manifest.get('schema') != 'mits-kids-build-manifest-v1':
        raise RuntimeError('Unknown signed build-manifest schema.')
    expected = expected_signer.replace(':', '').lower()
    if manifest.get('signing', {}).get('certificate_sha256') != expected:
        raise RuntimeError('Manifest signer field does not match the trusted certificate.')
    artifacts = manifest.get('artifacts')
    required = {'MITS-Kids-YouTube.apk', 'source-manifest.json', 'source.tar.gz',
                'pubspec.lock', 'pubspec.yaml', 'signing-certificate.der',
                'flutter-version.txt', 'toolchain.txt'}
    if not isinstance(artifacts, dict) or not required.issubset(artifacts):
        raise RuntimeError('The signed build manifest is missing required evidence.')
    for name, record in artifacts.items():
        path = output / name
        if Path(name).name != name or path.is_symlink() or not path.is_file():
            raise RuntimeError('A signed artifact is missing or has an unsafe path.')
        if artifact_record(path) != record:
            raise RuntimeError(f'Signed artifact does not match its recorded bytes: {name}')
    for field, name in [('apk_sha256', 'MITS-Kids-YouTube.apk'),
                        ('source_manifest_sha256', 'source-manifest.json'),
                        ('lockfile_sha256', 'pubspec.lock')]:
        if manifest.get(field) != artifacts[name]['sha256']:
            raise RuntimeError(f'Inconsistent signed manifest field: {field}')
    print(f'All {len(artifacts)} signed artifact hashes verified. Runtime acceptance remains separate.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keystore', type=Path)
    parser.add_argument('--alias')
    parser.add_argument('--password-file', type=Path, help='Owner-private local password file for a PKCS12 app key; never copied into evidence.')
    parser.add_argument('--sdk', type=Path, default=Path.home() / 'Android/Sdk')
    parser.add_argument('--keytool', default=shutil.which('keytool'))
    parser.add_argument('--output-root', type=Path)
    parser.add_argument('--verify', type=Path, help='Verify an existing evidence directory without signing credentials.')
    parser.add_argument('--expected-signer', help='Independently trusted application certificate SHA-256 for --verify.')
    args = parser.parse_args()
    keytool = shutil.which(args.keytool) if args.keytool else None
    if not keytool:
        parser.error('Provide an installed JDK keytool path.')
    args.keytool = str(Path(keytool).resolve())
    java = Path(keytool).resolve().with_name('java')
    if not java.is_file():
        parser.error('The selected keytool JDK must also provide the Java source launcher.')
    if args.verify:
        if not args.expected_signer:
            parser.error('--verify requires --expected-signer from a separately trusted source.')
        if args.keystore or args.alias or args.output_root or args.password_file:
            parser.error('--verify uses only public evidence; omit build/signing arguments.')
        verify_build_manifest(args.verify.resolve(), args.expected_signer, java)
        return
    if args.expected_signer:
        parser.error('--expected-signer is only used with --verify.')
    if not args.password_file and not sys.stdin.isatty():
        parser.error('Run this script in your own interactive local terminal for password entry.')
    if not args.keystore or not args.alias or not args.keystore.is_file():
        parser.error('Provide an existing application keystore and an installed keytool path. This tool never creates or rotates keys.')
    args.keystore = args.keystore.resolve()
    args.sdk = args.sdk.resolve()
    if args.output_root:
        args.output_root = args.output_root.resolve()
    if args.password_file:
        args.password_file = args.password_file.absolute()
    os.umask(0o077)
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    output_root = args.output_root or root / 'releases'
    output_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='release-', dir=output_root))
    report = {'status': 'INCOMPLETE', 'started_utc': datetime.now(timezone.utc).isoformat(), 'runtime_acceptance': 'NOT TESTED by this build script'}
    env = os.environ.copy()
    for name in ('MITS_VALIDATION_BUILD', 'MITS_RELEASE_STORE_PASSWORD', 'MITS_RELEASE_KEY_PASSWORD'):
        env.pop(name, None)

    def run(command, filename, command_env=None):
        print('Running:', ' '.join(map(str, command)), flush=True)
        result = subprocess.run(list(map(str, command)), env=command_env or env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (output / filename).write_text(result.stdout)
        if result.returncode:
            print(result.stdout, file=sys.stderr)
            raise RuntimeError(f'{filename} failed; see the local evidence directory.')
        return result.stdout

    try:
        # Test tools never receive the release passwords.
        run(['flutter', 'pub', 'get', '--offline'], 'pub-get.txt')
        run(['flutter', 'analyze', '--no-pub', 'lib', 'test', 'integration_test', 'tools/live_source_probe.dart'], 'analysis.txt')
        run(['flutter', 'test', '--no-pub', '--reporter', 'expanded'], 'flutter-tests.txt')
        run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'tools/tests', '-p', 'test_*.py'], 'python-tests.txt')
        run([sys.executable, '-B', 'tools/test_native.py'], 'native-tests.txt')
        # Flutter skips plugin regeneration under --no-pub. A preceding test
        # build can leave integration_test in the generated Java registrant,
        # while Gradle correctly excludes that dev dependency from release.
        # Prepare release tooling before passwords enter any child process.
        checked_lock = (root / 'pubspec.lock').read_bytes()
        run(['flutter', 'build', 'apk', '--release', '--config-only'], 'release-config.txt')
        if (root / 'pubspec.lock').read_bytes() != checked_lock:
            raise RuntimeError('Release configuration changed pubspec.lock; review dependencies and rerun all checks.')
        run([sys.executable, '-B', 'tools/audit_dependencies.py', 'pubspec.lock'], 'dependency-audit.json')
        inventory_env = dict(env, MITS_DEPENDENCY_INVENTORY=str(output / 'android-dependencies.json'))
        run([root / 'android/gradlew', '-p', root / 'android', '--no-daemon',
             '-I', root / 'tools/android_inventory.init.gradle', ':app:mitsDependencyInventory'],
            'android-inventory.txt', inventory_env)
        run([sys.executable, '-B', 'tools/audit_android.py', output / 'android-dependencies.json'],
            'android-dependency-audit.json')
        report['source_manifest_sha256'] = snapshot(root, output)
        report['lockfile_sha256'] = hashlib.sha256((root / 'pubspec.lock').read_bytes()).hexdigest()
        shutil.copy2(root / 'pubspec.lock', output)
        shutil.copy2(root / 'pubspec.yaml', output)
        run(['flutter', '--version'], 'flutter-version.txt')
        run(['flutter', 'doctor', '-v'], 'toolchain.txt')
        local_password = local_signing_password(args.password_file) if args.password_file else None
        signing = env.copy()
        signing.update({
            'MITS_RELEASE_STORE_FILE': str(args.keystore.resolve()),
            'MITS_RELEASE_KEY_ALIAS': args.alias,
            'MITS_RELEASE_STORE_PASSWORD': local_password or getpass.getpass('Keystore password (local only): '),
            'MITS_RELEASE_KEY_PASSWORD': local_password or getpass.getpass('Private-key password (local only): '),
            'GRADLE_OPTS': env.get('GRADLE_OPTS', '') + ' -Dorg.gradle.daemon=false',
        })
        local_password = None
        try:
            run([args.keytool, '-exportcert', '-keystore', args.keystore.resolve(), '-alias', args.alias,
                 '-storepass:env', 'MITS_RELEASE_STORE_PASSWORD', '-file', output / 'signing-certificate.der'], 'certificate-export.txt', signing)
            expected = hashlib.sha256((output / 'signing-certificate.der').read_bytes()).hexdigest()
            run(['flutter', 'build', 'apk', '--release', '--no-pub'], 'release-build.txt', signing)
            apk = root / 'build/app/outputs/flutter-apk/app-release.apk'
            checks = run([sys.executable, '-B', 'tools/check_apk.py', apk, '--sdk', args.sdk], 'apk-check.txt')
            actual = [value.replace(':', '').lower() for value in re.findall(r'certificate SHA-256 digest:\s*([0-9a-fA-F:]+)', checks)]
            if actual != [expected]:
                raise RuntimeError('APK signer does not uniquely match the selected keystore certificate.')
            analyzer = sorted((args.sdk / 'cmdline-tools').glob('*/bin/apkanalyzer'))[-1]
            manifest = ET.fromstring(run([analyzer, 'manifest', 'print', apk], 'AndroidManifest.xml'))
            android = '{http://schemas.android.com/apk/res/android}'
            report.update({'application_id': manifest.get('package'), 'version_name': manifest.get(android+'versionName'),
                           'version_code': manifest.get(android+'versionCode'), 'signer_sha256': expected})
            if report['application_id'] != 'com.example.mits_kids_youtube':
                raise RuntimeError('Unexpected package identity; review it before delivery.')
            with zipfile.ZipFile(apk) as archive:
                abis = sorted({name.split('/')[1] for name in archive.namelist() if name.startswith('lib/') and name.endswith('/libflutter.so')})
            if set(abis) != {'armeabi-v7a', 'arm64-v8a', 'x86_64'}:
                raise RuntimeError(f'Expected universal Flutter ABIs, found {abis}.')
            target = output / 'MITS-Kids-YouTube.apk'
            shutil.copy2(apk, target)
            checksum = hashlib.sha256(target.read_bytes()).hexdigest()
            (output / 'SHA256SUMS').write_text(checksum + '  MITS-Kids-YouTube.apk\n')
            report.update({'apk_sha256': checksum, 'apk_bytes': target.stat().st_size, 'abis': abis})
            signer_tool = root / 'tools/SignReleaseManifest.java'
            description = json.loads(run([java, signer_tool, 'describe', output / 'signing-certificate.der'], 'manifest-signer.json'))
            if description['certificate_sha256'] != expected:
                raise RuntimeError('Manifest signer does not match the verified APK signer.')
            signed_manifest = build_manifest(output, report, description)
            (output / 'build-manifest.json').write_text(json.dumps(signed_manifest, indent=2, sort_keys=True) + '\n')
            run([java, signer_tool, 'sign', output / 'build-manifest.json', args.keystore.resolve(), args.alias,
                 output / 'signing-certificate.der', output / 'build-manifest.sig'], 'manifest-sign.txt', signing)
            signing.clear()
            # Public verification receives no keystore or passwords.
            run([sys.executable, '-B', 'tools/release.py', '--verify', output.resolve(),
                 '--expected-signer', expected, '--keytool', args.keytool], 'manifest-verify.txt')
            report.update({'status': 'BUILD_AND_SIGNATURE_VERIFIED', 'manifest_signature_verified': True,
                           'build_manifest_sha256': artifact_record(output / 'build-manifest.json')['sha256'],
                           'manifest_signature_algorithm': description['signature_algorithm']})
            (output / 'RELEASE-NOTES.md').write_text(
                '# MITS Kids release evidence\n\n' + '\n'.join(f'- {key}: {value}' for key, value in report.items()) +
                '\n\nExact signed release runtime acceptance remains separate. The owner requested file transfer and hands-on Lenovo tablet testing; this build script does not claim those results.\n'
            )
        finally:
            signing.clear()
    finally:
        (output / 'release.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Non-secret release evidence:', output)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from None

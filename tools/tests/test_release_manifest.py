"""Public verification and tampering checks using disposable /tmp keys only."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from release import artifact_record, build_manifest  # noqa: E402
from source_snapshot import snapshot  # noqa: E402


class ReleaseManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        keytool = shutil.which('keytool')
        if not keytool:
            raise unittest.SkipTest('A JDK keytool is required for detached-signature tests.')
        cls.keytool = Path(keytool).resolve()
        cls.java = cls.keytool.with_name('java')
        cls.temporary = tempfile.TemporaryDirectory(prefix='mits-manifest-signing-test-', dir='/tmp')
        cls.root = Path(cls.temporary.name)
        cls.password = secrets.token_urlsafe(32)
        cls.env = os.environ.copy()
        cls.env.update(MITS_RELEASE_STORE_PASSWORD=cls.password, MITS_RELEASE_KEY_PASSWORD=cls.password)
        cls.public_env = os.environ.copy()
        cls.public_env.pop('MITS_RELEASE_STORE_PASSWORD', None)
        cls.public_env.pop('MITS_RELEASE_KEY_PASSWORD', None)
        try:
            for name, algorithm in [('rsa', 'RSA'), ('ec', 'EC')]:
                keystore = cls.root / (name + '.p12')
                subprocess.run([str(cls.keytool), '-genkeypair', '-keystore', str(keystore),
                                '-storetype', 'PKCS12', '-alias', 'fixture', '-keyalg', algorithm,
                                '-keysize', '2048' if algorithm == 'RSA' else '256',
                                '-validity', '2', '-dname', 'CN=Disposable Manifest Test',
                                '-storepass:env', 'MITS_RELEASE_STORE_PASSWORD',
                                '-keypass:env', 'MITS_RELEASE_KEY_PASSWORD'],
                               env=cls.env, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                subprocess.run([str(cls.keytool), '-exportcert', '-keystore', str(keystore),
                                '-alias', 'fixture', '-storepass:env', 'MITS_RELEASE_STORE_PASSWORD',
                                '-file', str(cls.root / (name + '.der'))],
                               env=cls.env, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except Exception:
            cls.env.clear()
            cls.temporary.cleanup()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.env.clear()
        cls.password = None
        cls.temporary.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='evidence-', dir=self.root)
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)

    def java_command(self, *args, signing=False):
        result = subprocess.run([str(self.java), str(TOOLS / 'SignReleaseManifest.java'), *map(str, args)],
                                env=self.env if signing else self.public_env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertNotIn(self.password, result.stdout)
        return result

    def prepare(self, algorithm='rsa'):
        for name in ['MITS-Kids-YouTube.apk', 'source-manifest.json', 'source.tar.gz',
                     'pubspec.lock', 'pubspec.yaml', 'flutter-version.txt', 'toolchain.txt']:
            (self.output / name).write_text('Disposable signature fixture: ' + name)
        shutil.copyfile(self.root / (algorithm + '.der'), self.output / 'signing-certificate.der')
        description = self.java_command('describe', self.output / 'signing-certificate.der')
        self.assertEqual(description.returncode, 0, description.stdout)
        metadata = json.loads(description.stdout)
        report = {
            'application_id': 'com.example.mits_kids_youtube',
            'version_name': '0.3.0', 'version_code': '3', 'abis': ['arm64-v8a'],
            'apk_sha256': artifact_record(self.output / 'MITS-Kids-YouTube.apk')['sha256'],
            'source_manifest_sha256': artifact_record(self.output / 'source-manifest.json')['sha256'],
            'lockfile_sha256': artifact_record(self.output / 'pubspec.lock')['sha256'],
            'runtime_acceptance': 'Unsigned manual status',
        }
        (self.output / 'release.json').write_text(json.dumps(report))
        (self.output / 'RELEASE-NOTES.md').write_text('Mutable manual acceptance notes')
        manifest = build_manifest(self.output, report, metadata)
        self.assertNotIn('runtime_acceptance', manifest)
        self.assertNotIn('release.json', manifest['artifacts'])
        self.assertNotIn('RELEASE-NOTES.md', manifest['artifacts'])
        (self.output / 'build-manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
        signed = self.java_command('sign', self.output / 'build-manifest.json', self.root / (algorithm + '.p12'),
                                   'fixture', self.output / 'signing-certificate.der',
                                   self.output / 'build-manifest.sig', signing=True)
        self.assertEqual(signed.returncode, 0, signed.stdout)
        return metadata['certificate_sha256']

    def verify(self, fingerprint):
        return subprocess.run([sys.executable, '-B', str(TOOLS / 'release.py'), '--verify', str(self.output),
                               '--expected-signer', fingerprint, '--keytool', str(self.keytool)],
                              env=self.public_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_rsa_public_verification_and_mutable_manual_notes(self):
        fingerprint = self.prepare()
        (self.output / 'release.json').write_text('{"runtime_acceptance":"manually recorded later"}')
        result = self.verify(fingerprint)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('signed artifact hashes verified', result.stdout)

    def test_ec_key_and_modified_apk_fail_artifact_verification(self):
        fingerprint = self.prepare('ec')
        self.assertEqual(self.verify(fingerprint).returncode, 0)
        (self.output / 'MITS-Kids-YouTube.apk').write_bytes(b'changed APK bytes')
        result = self.verify(fingerprint)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Signed artifact does not match', result.stdout)

    def test_changed_manifest_and_untrusted_certificate_are_rejected(self):
        fingerprint = self.prepare()
        original = (self.output / 'build-manifest.json').read_bytes()
        (self.output / 'build-manifest.json').write_bytes(original + b' ')
        self.assertNotEqual(self.verify(fingerprint).returncode, 0)
        (self.output / 'build-manifest.json').write_bytes(original)
        other = hashlib.sha256((self.root / 'ec.der').read_bytes()).hexdigest()
        self.assertNotEqual(self.verify(other).returncode, 0)
        shutil.copyfile(self.root / 'ec.der', self.output / 'signing-certificate.der')
        self.assertNotEqual(self.verify(fingerprint).returncode, 0)

    def test_signing_rejects_a_certificate_from_a_different_key(self):
        manifest = self.output / 'build-manifest.json'
        manifest.write_text('{"fixture":true}\n')
        result = self.java_command('sign', manifest, self.root / 'rsa.p12', 'fixture',
                                   self.root / 'ec.der', self.output / 'build-manifest.sig', signing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.output / 'build-manifest.sig').exists())
        no_password = self.java_command('sign', manifest, self.root / 'rsa.p12', 'fixture',
                                       self.root / 'rsa.der', self.output / 'build-manifest.sig')
        self.assertNotEqual(no_password.returncode, 0)

    def test_snapshot_includes_java_and_excludes_signing_material(self):
        source = self.output / 'project'
        (source / 'tools').mkdir(parents=True)
        (source / 'tools/Signer.java').write_text('class Signer {}')
        (source / 'tools/private.jks').write_bytes(b'not a source file')
        destination = self.output / 'snapshot'
        snapshot(source, destination)
        files = json.loads((destination / 'source-manifest.json').read_text())
        self.assertEqual(set(files), {'tools/Signer.java'})


if __name__ == '__main__':
    unittest.main()

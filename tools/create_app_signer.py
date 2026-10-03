#!/usr/bin/env python3
"""Create a dedicated permanent app signer in a new private local directory.

Never reuse an infrastructure CA, print a password, overwrite a key, or copy
the private directory into release evidence. Back it up securely after creation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess


def create(directory, keytool):
    os.umask(0o077)
    directory = directory.absolute()
    directory.mkdir(mode=0o700, parents=False, exist_ok=False)
    password_path = directory / 'keystore-password.txt'
    keystore = directory / 'mits-kids-release.p12'
    certificate = directory / 'app-signing-certificate.der'
    password = secrets.token_urlsafe(48)
    with password_path.open('x') as stream:
        stream.write(password + '\n')
    environment = os.environ.copy()
    environment['MITS_NEW_APP_KEY_PASSWORD'] = password
    password = None
    try:
        generated = subprocess.run([
            keytool, '-genkeypair', '-storetype', 'PKCS12', '-keystore', str(keystore),
            '-alias', 'mits-kids', '-keyalg', 'RSA', '-keysize', '3072',
            '-sigalg', 'SHA256withRSA', '-validity', '10000',
            '-dname', 'CN=MITS Kids App Signing,OU=Android Applications,O=MITS',
            '-ext', 'BC=ca:false', '-ext', 'KU=digitalSignature',
            '-storepass:env', 'MITS_NEW_APP_KEY_PASSWORD',
            '-keypass:env', 'MITS_NEW_APP_KEY_PASSWORD',
        ], env=environment, capture_output=True, text=True)
        if generated.returncode:
            raise RuntimeError('Key creation failed. The private directory was retained for local inspection; no key was overwritten.')
        exported = subprocess.run([
            keytool, '-exportcert', '-keystore', str(keystore), '-alias', 'mits-kids',
            '-storepass:env', 'MITS_NEW_APP_KEY_PASSWORD', '-file', str(certificate),
        ], env=environment, capture_output=True, text=True)
        if exported.returncode:
            raise RuntimeError('Public certificate export failed. Keep the private directory; do not recreate or overwrite the key.')
    finally:
        environment.clear()
    for path in (password_path, keystore, certificate):
        path.chmod(0o600)
    info = {'purpose': 'Permanent MITS Kids APK signing identity; independent of infrastructure CA',
            'keystore': str(keystore), 'alias': 'mits-kids',
            'password_file': str(password_path),
            'certificate_sha256': hashlib.sha256(certificate.read_bytes()).hexdigest(),
            'private_backup_status': 'Owner must copy this private directory to a separate encrypted backup.'}
    (directory / 'signing-identity.json').write_text(json.dumps(info, indent=2) + '\n')
    (directory / 'README-PRIVATE.txt').write_text(
        'PERMANENT APPLICATION SIGNING KEY — KEEP FOR ALL FUTURE MITS KIDS UPDATES\n\n'
        'This directory is private. Back up the entire directory to a separate encrypted location.\n'
        'The password file is plaintext, protected by owner-only filesystem permissions.\n'
        'Do not upload this directory, place it in source control, or copy it to the tablet.\n'
        'Only APK/checksum/public-certificate files belong in a distribution bundle.\n'
        'This key only signs this app; it is independent of any other certificate authority or key.\n'
    )
    return info


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--keytool', default=shutil.which('keytool'))
    args = parser.parse_args()
    if not args.keytool:
        parser.error('An installed JDK keytool is required.')
    try:
        print(json.dumps(create(args.directory, args.keytool), indent=2))
    except (OSError, RuntimeError) as failure:
        parser.exit(1, str(failure) + '\n')

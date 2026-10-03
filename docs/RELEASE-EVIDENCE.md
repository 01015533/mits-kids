# Signed release evidence

`tools/release.py` builds with an existing application signing identity, checks
the resulting APK, and signs a separate build manifest using that same private
key. It never generates or rotates the application key. Final tablet identity
and existing-install compatibility must be checked before updating an installed app.

## Application signing identity

Every update must be signed with the same application key as the installed app.
The maintainer's builds use a dedicated RSA-3072 key whose public certificate
SHA-256 is
`f3f945b2ae802bfba2d000ccb0a560ed18477bd725ab14de07752ad5037615ff`.
APKs signed with any other key are not the maintainer's releases.

Keep your own key outside the repository. `tools/create_app_signer.py` creates
an owner-only directory containing a PKCS12 key and a generated password file.
The password file is plaintext protected by filesystem permissions, not a
password manager. Keep the entire directory in a separate encrypted backup; it
is required for future compatible app updates. Never upload it with the APK or
copy it onto the tablet.

To build with such an identity without exposing a password in command arguments:

```bash
python3 tools/release.py \
  --keystore /path/to/app-signing/release.p12 \
  --alias your-key-alias \
  --password-file /path/to/app-signing/keystore-password.txt
```

The optional password-file mode rejects symlinks, non-owner files and group/world
access. It reads the credential only after automated checks and passes it only to
the signing processes. The file and key are outside the source snapshot and
public evidence. Without this option, the script retains hidden terminal prompts.

`tools/create_app_signer.py` is a separate first-identity setup tool. It requires
a new directory and refuses to overwrite any existing signing identity. Normal
release builds must reuse the retained key, not run the creation tool again.

## Interactive alternative

Run from your own local terminal, using the actual retained key and alias:

```bash
cd /path/to/MITSTUBE-Kids
python3 tools/release.py \
  --keystore /path/to/existing/application-release.jks \
  --alias existing-application-alias
```

If needed, pass `--keytool /path/to/jdk/bin/keytool`; the signer uses the `java`
source launcher from that same JDK. Java 17 or newer is required. Passwords are
entered through local hidden prompts. They are passed to the build/signer only
through process environment variables, never command arguments, source files,
manifest fields or copied evidence. The signing environment is cleared after
the manifest signature is created and on errors. This limits retention; it does
not promise erasure of every immutable string or OS/runtime memory copy.

The script runs automated checks before collecting signing passwords. An error
leaves an evidence directory marked incomplete. A release build is not a claim
that the exact APK passed emulator or tablet acceptance.

## Artifacts and trust

The evidence directory contains:

- The checked universal APK and its SHA-256 checksum.
- A source archive, per-file source manifest and dependency lockfile.
- Application identity/version, supported ABIs and toolchain records.
- Automated test, dependency-audit and APK-inspection evidence produced by the
  build workflow.
- The exact resolved Android release Maven inventory and its OSV review,
  alongside the separate Pub lockfile advisory review.
- The public application signing certificate in DER form.
- `build-manifest.json`, which records the exact hashes/sizes of immutable build
  evidence, plus `build-manifest.sig`, its detached signature.
- `release.json` and release notes, which remain separate from the signed
  manifest so later manual acceptance records are not misrepresented as signed
  build results.

`tools/SignReleaseManifest.java` reads the existing private key from its keystore
and signs the exact JSON bytes. RSA, EC and DSA application keys use SHA-256 with
their corresponding JCA signature algorithms. It rejects a certificate that
does not match the selected key entry. The release workflow first verifies the
APK certificate against that same selected public certificate; the APK and
manifest therefore share the chosen signing identity.

To verify a copied evidence directory, obtain the expected application
certificate SHA-256 through a separately trusted record, then run:

```bash
python3 tools/release.py \
  --verify /path/to/release-evidence-directory \
  --expected-signer EXPECTED_APPLICATION_CERTIFICATE_SHA256
```

This mode requires no keystore, password or Android SDK access. It verifies the
detached signature, requires the provided certificate to match the independently
expected fingerprint, then checks every signed artifact hash and size. A valid
signature does not make a newly supplied adjacent certificate trustworthy by
itself. Do not copy the fingerprint from an untrusted evidence bundle and treat
that as an independent identity check.

Unsigned manual notes can be updated without invalidating the build signature.
Changing the signed JSON, APK, source snapshot, lockfile or recorded build logs
causes verification to fail. Signing does not claim that a human reviewed those
files or that all possible security/device tests passed.

## Rebuilding and reproducibility limits

The source/lockfile hashes and toolchain records identify the captured inputs
for reconstructing the build. They provide traceability even when no Git
revision is available in the imported project. They are not a claim of a
hermetic or bit-for-bit reproducible build.

The archive records filesystem metadata and creation time. Android/Flutter/JDK
versions, downloaded Maven/native dependencies, build timestamps, caches,
operating-system behavior and signing details may change output bytes. Matching
source does not prove that a later APK will have an identical hash. A fresh
build must repeat the checks, produce its own signed manifest, and undergo its
own device acceptance. Never reuse an older checksum as evidence for a new APK.

The signature tests create disposable RSA/EC keystores only in temporary `/tmp`
directories and remove them afterwards. Those fixtures are not application
release identities and must not be used for tablet distribution.

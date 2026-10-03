# Historical validation — security and offline update 0.3.0+3

This is the imported authoring-environment record, not the current workstation
results. The adjacent dependency-audit.json now describes the current lockfile.
See VALIDATION.md for measured 0.4 results.

Checked with Flutter 3.47.4 / Dart 3.13.3, matching the user's Flutter SDK.

| Check | Measured result |
| --- | --- |
| Dart analysis, `dart analyze lib test` | No issues found. |
| Flutter unit and widget tests | 35 passed. |
| Python updater and APK-checker tests | 13 passed. |
| Native Kotlin helper compilation | All four helpers compile against Android API 36 and Flutter embedding. |
| Native derivation and backoff tests | 14 JVM checks passed, including an independent PBKDF2/HMAC fixture. |
| Resolved Dart dependencies | OSV returned no known advisory matches for 94 hosted packages. See `dependency-audit.json`. |
| Android debug APK | Built successfully for x86_64 using the Flutter 3.47.4 Android template. |
| Android release APK | Built successfully for x86_64, including fatal release lint, with a disposable validation certificate. |
| Actual release APK inspection | Passed manifest, permission scope, exported component, TLS policy, backup/transfer policy, debugging and signature checks. Resource paths were resolved from the compiled resource table after release shrinking. |
| Release signing gate | A Gradle release request without signing credentials was correctly rejected before building. |

Flutter tests cover the setup gate, PIN confirmation, session expiry,
background/in-flight authentication invalidation, approval and lock checks,
HTTPS destinations and redirects, credential stripping, duplicate saves,
eight-slot capacity, actual filesystem writes, interrupted/truncated transfers,
failed database commits, mux failure cleanup, file integrity, symlink escape,
current content-rule revocation, and actual SQLite persistence and migration.

Python tests exercise guarded installation and restoration, original-MVP and
previous-update upgrades, preserving the package name, rejecting custom source
and signing changes, permission checks, repeated installation, and refusing
rollback over subsequent user edits. APK-checker unit tests exercise manifest
policy decisions. The checker was also run successfully against the built release
APK. The dependency-added profiling receiver is removed in release builds.

The test APK and disposable signing key are not distributed. Build your tablet
APK with your own persistent signing key and run the same checker on that exact
file. This verification did not build or run the ARM tablet variant.

The JVM checks do not execute Android Keystore or Android lifecycle callbacks.
Flutter media tests use a fake muxer and do not prove native codec playback.
There is no Android emulator in this validation environment.

A live public-video lookup timed out with a 90-second budget. Actual YouTube
media transfer was not verified. This does not establish whether the cause is
the test environment, YouTube availability, or extractor behaviour. No claim is
made that every YouTube video is downloadable.

The advisory check covers the resolved Pub lockfile, not all Android Maven
dependencies, the OS, WebView, or unknown vulnerabilities. The updater preserves
unrelated dependencies in an existing project, so run the included checker on
your resulting `pubspec.lock` before release.

See `SECURITY-UPDATE.md` for the required emulator acceptance checks. In
particular, verify PIN migration/cooldown across restart and reboot, parent
locking, WebView restrictions, a complete download, and playback after disabling
connectivity inside Android.

Validation used temporary SDK/JDK installations and CI mode. Build tooling uses
the environment's existing trusted proxy certificate; the application's TLS
policy remains unchanged. No certificate-verification bypass was used.

# Historical validation — 0.4.0+4

This report identifies the preceding validation-only build. It does not certify
the current approved-download background service or 0.4.1 tablet APK.

Measured on the maintainer's Fedora workstation, 17–18 September 2026 UTC.
Application ID remains `com.example.mits_kids_youtube`; offline database schema is 3.

The historical imported report is preserved separately in
[VALIDATION-0.3-HISTORICAL.md](VALIDATION-0.3-HISTORICAL.md). Its timeout and counts
have not been retrospectively relabelled as successful tests.

## Automated results

| Check | Measured result |
| --- | --- |
| Flutter/Dart analysis, including integration tests and live probe | PASS — no issues found. |
| Flutter unit/widget tests | PASS — 87 tests. Covers storage reserve, duplicate/slot rules, crash recovery, encrypted backup state/publication, PIN UI and narrow enlarged-text parent layouts. |
| Python APK policy and release-manifest tests | PASS — 21 tests including source-snapshot completeness/exclusions and emulator-only security-runner guards. Includes valid signatures, altered evidence and certificate substitution. |
| Pure Kotlin security/storage/archive checks | PASS — 62 checks: 31 backup codec/manifest, 7 credential epoch, 14 derivation/backoff, 10 path containment. |
| Dart dependencies | PASS — OSV returned no known matches for 99 hosted dependencies in the current lockfile. |
| Android dependencies | PASS — exact release runtime inventory contains 112 Maven coordinates; OSV returned no known matches. |
| Native Android PIN migration/persistence | PASS — wrong old PIN and invalid replacement rejected; migration committed and removed legacy hash; new PIN survived process restart and reboot; five failures retained cooldown across restart and reboot. |
| Same-boot wall-deadline independence | PASS with a fixture simulation — set only the isolated app's wall deadline to zero; cooldown still followed its monotonic deadline. No actual system clock was changed. |
| Native Android acceptance | PASS — 4 tests: setup/Keystore authentication/late-result revocation, current-PIN change, private free-space path guard, AVC/AAC mux and native playback/pause/seek. |
| Real YouTube save | PASS — approved Blender's Big Buck Bunny (`YE7VzlLtp-4`), downloaded 25,333,815 bytes at 640×360; native initialization/play/pause/seek passed. |
| Offline after process restart | PASS — force-stopped validation app, disabled Wi-Fi inside Android, verified Wi-Fi off and absence of cellular hardware, relaunched and played/paused/sought the same local file. Original network state restored afterwards. |
| Encrypted backup through Android document picker | PASS — exported a native codec fixture, required parent unlock after both pickers, rejected wrong password, inspected without publication, freshly approved restore, verified identical hash and played restored media. |
| Universal release build | PASS — 58,077,219 bytes; ARM64, ARMv7 and x86_64. The exact test-signed APK passed policy/signature inspection. |
| Missing-signing guard | PASS — Gradle refused release assembly without signing configuration. |
| Production release | Pending permanent application signing identity and final emulator/tablet acceptance. |

The security persistence harness used a new process for each stage. Reboot increased
the emulator boot count from 3 to 4; the native layer reinstated its conservative
30-second cooldown, then accepted the migrated PIN after that delay and cleared
the failure state. Details and the guarded repeatable procedure are in
[SECURITY-PERSISTENCE-TESTS.md](SECURITY-PERSISTENCE-TESTS.md).

The complete real download took about 13.5 seconds in the initial measured run;
subsequent duplicate/offline checks reused the verified saved copy. Saved media
SHA-256: `14a7856e2c8e2df790b36af80e04acfcb0a22bd727c6b79978e1d7cf499e2a2b`.
This proves one source worked at test time; extractor availability remains
video-, network- and time-dependent.

Host integrity measurement retained full per-open SHA-256 verification: a
256 MiB file took about 1.68 seconds with the existing streaming approach and
1.69 seconds in a separate isolate, with observed event-loop gaps around 11–13
ms. There was no measured benefit justifying an implementation change. Physical
flash performance and perceived delay remain tablet acceptance items.

## Release build evidence

The test-signed APK is `build/validation-release/MITS-Kids-VALIDATION-ONLY.apk`.
SHA-256: `de05c1f8b78dc95a0bab06aab5788452f8dd90ada7558c29cc9781fa2d43b12e`.
It retains the production package ID, version 0.4.0/code 4, minimum API 26 and
target API 36. The actual APK check confirmed the expected permissions,
launcher-only exported component, disabled test/backup/cleartext policy,
non-debuggable release, compiled policy resources and a unique matching signer.

This artifact and `build/app/outputs/flutter-apk/app-release.apk` use the same
**temporary validation certificate**. Neither is intended for distribution or
installation over an existing app. The temporary private key was deleted after
verification; its public certificate and measured build report are retained.
No runtime acceptance is claimed for this exact release APK.

An initial release build exposed stale integration-test plugin registration.
The release script now runs Flutter's supported release `--config-only`
preparation after tests, checks the lockfile remains unchanged, then builds with
`--no-pub`. The corrected release completed successfully and was rebuilt after the final
settings-persistence fix; the checksum above identifies that final candidate. The initial failure is
retained alongside the successful result so this issue is traceable.

## Environment and isolation

- Flutter 3.47.4, Dart 3.13.3, Android Studio JBR 25.0.3, Gradle 9.3.1,
  Android Gradle Plugin 9.1.0, Kotlin 2.4.0; compile/target API 36.
- Medium Tablet emulator, Android 15 / API 35, x86_64; installed System WebView
  `com.google.android.webview` 124.0.6367.219. Full live WebView acceptance was not
  established by the native/storage tests. Wi-Fi was confirmed restored to on.
- Integration tests use **only** `com.example.mits_kids_youtube.validation`,
  labelled MITS Kids validation, and reject the production private-data path.
  Fixture PINs/passwords/media are test-only. The security persistence
  runner explicitly clears only that disposable validation package before
  seeding a known legacy fixture; it never clears the production package. `--no-uninstall` preserves fixture
  data between restart tests. No production app was uninstalled or cleared.
- No physical tablet ADB connection, signing-key rotation, network-segmentation
  change, application TLS weakening or screenshot-security removal occurred.
- Advisory checks cover known OSV entries for the recorded Pub/Maven versions;
  they do not audit Android OS/System WebView or prove absence of vulnerabilities.

## Remaining acceptance

The recorded emulator playback checks observe native position, dimensions,
duration and error status. A human still needs to confirm visible picture,
audible sound and audio/video synchronization on the target tablet.

The exact final signed release must be checked with the chosen retained signer,
then exercised on an isolated emulator and the actual tablet. Same-signer update
with preserved PIN/settings/downloads cannot be established until the current
installed APK/signing history is identified. Full live WebView browsing and
permission/navigation behavior, rotation, TalkBack, maximum-size/eight-video
backups, low-space behavior and process interruption on actual hardware also
remain acceptance items; unit tests are not substituted for those observations.

Downloads and active backup operations still cancel when Parent locks or the
app backgrounds, with a five-minute parent session. The proposed change allowing
an already-approved download to finish after lock remains a maintainer policy
decision. Kiosk/device management and general MP4 import are excluded.

Local measured logs are collected under `build/validation-evidence/`. The release
script reruns its build checks and generates a fresh signed evidence set; these
local development results are not represented as results for a future APK.

# Isolated Android security persistence checks

The staged harness tests the real production `mits_kids/parent_security` channel on a disposable validation installation. It adds no production authentication method or bypass. Known public fixture PINs appear only in test sources; no production PIN, verifier, signing key or private certificate is supplied to the operator script.

The operator requires all of the following before installation or data reset:

- An explicit serial matching `emulator-<number>` and `ro.kernel.qemu=1` from that device.
- The exact package `com.example.mits_kids_youtube.validation`, supplied explicitly.
- `--reset-validation-data`, authorizing replacement of that disposable fixture's data.
- An APK whose actual manifest application ID matches that same validation package.

The script can install/update and clear only that package. It does not uninstall an application, connect a physical device, change a system clock, change production app identity or touch production app data. Run it after any other validation-app acceptance checks whose temporary library/PIN state you want to preserve.

## Build and run

Build the dedicated debug probe once. The existing Gradle validation switch refuses release builds and gives this APK the isolated package ID. The additional Dart define enables only the probe harness; the Dart package/path guard still refuses every other installation.

```bash
MITS_VALIDATION_BUILD=1 flutter build apk --debug --no-pub \
  --target-platform android-x64 \
  --target integration_test/security_persistence_probe.dart \
  --dart-define=MITS_SECURITY_VALIDATION=true

python3 tools/test_security_persistence.py \
  --emulator emulator-5554 \
  --package com.example.mits_kids_youtube.validation \
  --apk build/app/outputs/flutter-apk/app-debug.apk \
  --reset-validation-data \
  --simulate-wall-deadline \
  --reboot-emulator
```

Supply `--sdk /absolute/android/sdk` if the SDK is not in `$ANDROID_SDK_ROOT` or `~/Android/Sdk`. `apkanalyzer` must be installed under `cmdline-tools/latest/bin`. `--evidence-dir /chosen/path` keeps the non-secret JSON reports at a specific location; otherwise the script prints its fresh temporary evidence directory.

The script restarts the same compiled APK through Android's activity manager between stages. No Flutter rebuild takes time out of the 30-second cooldown window. `integration_test/security_persistence_test.dart` also wraps the same checks for Flutter's integration-test runner, but the operator probe is preferable for process/reboot timing.

## What the stages establish

| Stage | Measured assertion |
| --- | --- |
| `migration` | An isolated legacy SHA-256 fixture is configured; a wrong old PIN fails; an invalid replacement leaves legacy state intact; the correct old PIN migrates to the stronger verifier; the legacy key is removed after commit; the old PIN then fails and the new PIN works. |
| `seed_cooldown` | The migrated PIN survives a real process stop/restart. Five actual incorrect native authentication attempts produce the longer 30-second delay, and failure count 5 is present on disk. |
| `process_probe` | A different app process, on the same Android boot, rejects the correct PIN while retaining the existing failure count and monotonic deadline. If the launch misses the cooldown window, the harness fails instead of claiming a pass. |
| `wall_deadline_probe` | Optional simulation: while only the validation app is stopped, the operator changes its fixture `untilWall` field to zero while preserving `boot` and `untilElapsed`. A new process still rejects the correct PIN under the monotonic deadline. **This is not an actual OS clock-change test.** |
| `reboot_probe` | Optional emulator reboot increments Android's boot count. The correct PIN remains blocked by a fresh conservative 30-second delay; the delay is rebound to the new boot. After expiry, the migrated PIN works and durable retry state is cleared. |
| `recover_after_cooldown` | Used when reboot is omitted: allow the remaining bounded cooldown to expire and leave the validation fixture usable. The script explicitly reports reboot persistence as not tested. |

The fixture reports contain booleans, stage labels, PIDs, boot counts, cooldown durations and the probe APK checksum. They do not contain authentication tokens, salt/verifier values, PINs or Keystore material. The script force-stops the validation app when finished and leaves its known migrated fixture credential intact.

## Limits

This suite establishes emulator behavior for the installed debug validation artifact. It does not establish release shrinking behavior, hardware-backed Keystore availability, physical-tablet migration, audible media playback, destructive recovery after Keystore loss or actual system wall-clock changes. Test the exact signed production APK on the target tablet separately.

If actual clock-change testing is needed, use a separate disposable emulator so its clock/TLS changes cannot affect other running tests or applications. Record that as its own acceptance result; do not relabel the isolated `untilWall` simulation as a real clock-change pass.

Host guard checks are available with:

```bash
python3 -m unittest discover -s tools/tests -p test_security_persistence_guards.py -v
```

## Recorded acceptance run — 18 September 2026

The dedicated x86_64 debug validation APK passed all five stages on `emulator-5554`. Migration removed the legacy hash only after committing the stronger verifier; the old PIN then failed and the replacement PIN succeeded. Five real failures persisted across a process restart, with 28 seconds of cooldown still reported. Setting only the stopped validation fixture's wall deadline to zero left 26 seconds of monotonic cooldown in force. No operating-system clock was changed.

An actual emulator reboot advanced Android's boot count from 3 to 4. Authentication was initially refused for a conservative 30 seconds. After that delay, the migrated PIN and Keystore verifier still worked, and successful authentication cleared the durable failure state. The operator left only the disposable validation app force-stopped.

The tested probe APK SHA-256 was `9af2f95f21250fe58019196c7e6ae984c7ccad6723cd77c1f237de56314f3df1`. This identifies the test probe, not the production release artifact. The local non-secret evidence is `/tmp/mits-security-persistence-evidence/summary.json`, with per-stage JSON reports beside it; the full operator log is `/tmp/mits-security-persistence.log`. The root validation run also copied these records to
`build/validation-evidence/security-persistence/` and the log to
`build/validation-evidence/security-persistence.txt` for local retention.

The full host suite, `python3 -m unittest discover -s tools/tests -v`, also passed all 21 tests, including the four guarded-operator tests.

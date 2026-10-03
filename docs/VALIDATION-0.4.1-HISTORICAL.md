# Historical 0.4.1+5 release evidence and owner feedback

The retained release evidence is `releases/release-bju75x7_`. It records clean
analysis, 113 Flutter tests, 28 Python tests, 62 Kotlin host checks, dependency
audits with no returned findings, successful APK policy/signature checks and a
verified signed build manifest. APK SHA-256:
`1495fd993b0848dc206810b29a841b22db13071a396331ecf8b1683035dd6f22`.

On 18 September 2026, the owner reported testing this APK on the supplied Lenovo
TB305FU (ZUI 17.0.10.324): "Tested it works well". This is positive owner-reported
real-tablet feedback. Individual checklist results, Android version and device
logs were not supplied; do not infer a pass for every detailed acceptance item.
This feedback predates the 0.4.2 touch lock, volume handling and repeat controls.

The original pre-test validation record follows.

---

# Validation — 0.4.1+5 tablet test release

The owner requested a directly transferable release APK for Lenovo Tab One
TB305FU, ZUI 17.0.10.324. This version uses the retained dedicated MITS Kids app
signer described in [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md). The infrastructure
CA and TLS private keys were not used.

## Changed behavior

One explicitly approved video save may now finish after Parent locks or while
the activity is backgrounded. Approval never unlocks Browse, Parent or backups;
it is bound to the original video, exists only in memory and cannot start a new
save. The overall job is bounded to 30 minutes, with explicit cancellation,
current-rule checks before/after publication, and cleanup on failure. An Android
dataSync foreground service provides progress/Cancel and a bounded wake lock.
Removing the task, process death or reboot does not automatically resume it.

Parent setup/authentication and backup authority keep their existing lifecycle
and five-minute limits. Kiosk/device management and general MP4 import remain
excluded. Storage reserve, byte limits, eight-slot capacity and full file hashes
remain enforced.

## Evidence scope

The release workflow reruns Dart analysis, all Flutter unit/widget tests, Python
policy/signature/credential-file checks, pure Kotlin security/archive tests, and
OSV queries against the resolved Pub and Android Maven inventories. It captures
these measured logs beside the APK and signs the immutable build manifest with
the same retained application key. Consult the final release evidence directory
for actual counts, timestamps, artifact hashes and signer verification.

The Android foreground-service code is compiled into the inspected release APK.
New Dart tests cover approval/lock boundaries, total timeout, stalled-stream
cancellation, cancellation during mux and database publication, rules revocation,
late callbacks, platform-job start/finish races, and locked UI progress/gates.
The APK checker requires the reviewed private dataSync service and cancellation
receiver and rejects other foreground service types or exported services.

**No new emulator run or physical-tablet test is claimed for 0.4.1.** The owner
requested real-tablet testing next. In particular, Lenovo background execution,
notification grant/denial, notification Cancel, process/task removal, native
foreground promotion, and audible/visible playback are current tablet acceptance
items. See [TABLET-TEST.md](TABLET-TEST.md).

The preceding actual emulator results (YouTube download, offline playback,
Keystore/PIN migration/cooldown/reboot and encrypted SAF round trip) are retained
in [VALIDATION-0.4-HISTORICAL.md](VALIDATION-0.4-HISTORICAL.md). They are useful
regression evidence, not substituted for testing this exact signed APK.

## Signing and delivery

Package remains `com.example.mits_kids_youtube`; version is 0.4.1/code 5;
minimum API is 26. The universal APK contains ARM64, ARMv7 and x86_64 builds.
Public app certificate SHA-256:
`f3f945b2ae802bfba2d000ccb0a560ed18477bd725ab14de07752ad5037615ff`.

The APK/checksum are safe to transfer; the private signer/password directory must
stay out of uploads. A previous differently signed app cannot be silently updated
with this signer. Preserve any existing installation and investigate a signature
conflict without automatically uninstalling or clearing data.

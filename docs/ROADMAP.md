# Maintainer decisions and release work

The maintainer decisions recorded here take precedence over older planning
notes and their optional backlog.

## Permanently excluded

Kiosk mode, device-owner provisioning, device administration and device
management will never be supported by this project. The maintainer has rejected
them because they could be misused. Do not add lock-task enforcement, home
launcher replacement, uninstall prevention, remote device control or privileged
admin enrollment. The APK policy checker rejects related manifest declarations.

Local MP4 import is excluded from the requested work. There is no import picker,
file-permission expansion or bypass around the review-and-approve download flow.

## Authorized work

- Resolve release permission checks and prepare a reproducible signed release.
- Correct slot/availability feedback, retain unavailable records for deliberate
  parent deletion, and show saved-file size and tablet free space.
- Check reserve storage before transfers/muxing and clean only recognized,
  unreferenced interrupted-save artifacts.
- Let an explicitly approved save finish after Parent locks or the app moves to
  the background. Only that approved video can continue; browsing and Parent
  controls still lock, and unapproved work is cancelled. Keep a 30-minute save
  limit with visible progress and safe cancellation.
- Support changing the parent PIN with the current PIN; provide honest recovery
  guidance with no reset shortcut or authentication bypass.
- Improve tablet layouts, wrapping, labels and accessibility.
- Provide a playback touch lock with deliberate hold-to-unlock and volume-key
  handling restricted to the foreground player; leave Power/Home/system actions
  available. Add in-player repeat settings remembered per video.
- Show each offline video as a picture taken from its saved file, and offer
  automatic playback of the next offline video.
- Evaluate the WebView dependency and migrate only when a compatible release
  justifies it.
- Support password-protected export/backup and authenticated restore without
  exporting the Android Keystore key or PIN verifier.
- Run local checks, emulator acceptance and the target-tablet checks; record
  measured results in [VALIDATION.md](VALIDATION.md).

This list records authorization, not a claim that every item has shipped. The
validation record and implementation determine completion. The package ID is
preserved and this source is version 0.4.8+12. The retained app signing identity
and Lenovo TB305FU target are recorded in the release and validation documents.

## WebView dependency decision

The current package remains pinned to `flutter_inappwebview` 6.2.0-beta.3 with
Android implementation 1.2.0-beta.3. The versions were reviewed against pub.dev;
the available stable versions are older, and the pinned Android prerelease
contains the Android Gradle Plugin 9 fix this project needs. Retain this pin until
a suitable newer compatible release is available, and verify website behavior
on the emulator and tablet after any change.

Sources: [Flutter package versions](https://pub.dev/packages/flutter_inappwebview/versions),
[Android package versions](https://pub.dev/packages/flutter_inappwebview_android/versions),
[Android compatibility fix](https://pub.dev/packages/flutter_inappwebview_android/versions/1.2.0-beta.3/changelog).

## Current implementation status

Storage/capacity fixes, disk reserve, orphan cleanup, current-PIN change,
parent storage and layout improvements, encrypted backup/restore, dependency
inventories, source snapshots, and detached release-manifest signatures are
implemented. The adaptive launcher icon and readable app name are set; the
existing package identity is preserved.

The WebView dependency and file hashing were reviewed; measured compatibility
and performance evidence did not justify replacing their current implementations.
See the validation record for the automated and actual Android results.

The maintainer approved background completion for an already approved save.
Version 0.4.1+5 gives that one job a bounded lifetime, progress/cancellation in
Offline and an Android download notification. It does not extend Parent access,
create new approvals, restart after process death, or change backup cancellation
on lock. That signed 0.4.1 release received positive owner-reported tablet testing.
Version 0.4.2 adds touch lock and per-video repeat; its physical button handling
and playback acceptance are a separate tablet check. Consult the validation
record for measured results.

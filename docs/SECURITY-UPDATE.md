# MITS Kids — security, offline storage and backup

Version 0.4.2 extended the 0.3 direct-download design with storage recovery, PIN
changes, encrypted backup and bounded background completion of explicitly
approved downloads, a playback touch lock and per-video repeat settings. The
local database upgrades to schema 3 while preserving existing saved records.
Android 8.0 / API 26 or newer is required.

## Behaviour to expect

- A parent completes a separate setup screen with a confirmed 6–12 digit PIN before the app is usable. Finish setup before handing the tablet to a child.
- An existing MVP PIN must be entered correctly before upgrading to a new 6–12 digit PIN. The old hash is removed only after the new credential commits successfully.
- Browse and Parent require a parent PIN. Parent access expires after five minutes, when choosing Offline, or when the app becomes inactive/backgrounded. A late authentication response cannot restore a locked session.
- Browse is anonymous and parent-only. Review a video and select **Approve & save**, then confirm the video title and channel while parent access is active. Locking cancels unapproved preparation. Once approved, only that exact save may finish after Parent locks or while switching apps; it cannot grant new approvals or access to Browse/Parent.
- Children use **Offline**, containing only parent-approved local videos. There is no live YouTube browsing in child mode. YouTube DOM filtering remains a convenience for parents, not the child-access boundary.
- The eight-slot limit includes earlier downloads. Downloads from older versions are preserved but unavailable to children because they lack approval and integrity metadata. Delete these in Parent, then review and download them again.
- Offline reports the number available to watch. Parent reports occupied slots,
  saved-file size and free tablet storage, including blocked/legacy records.
  Missing or damaged copies stay listed in Parent for deliberate deletion.
- Current channel-name/channel-ID and title-keyword rules are checked when listing and opening saved videos. Adding a block revokes access without deleting the file. The content hash is checked before playback.
- Offline playback requires no media server or internet connection. Approved saves keep running after the five-minute parent session ends, with a 30-minute limit for the complete save. Progress and Cancel remain available in Offline, and in the Android notification when allowed. Removing the app's task, force-stop, process death or restart stops the job; it does not resume automatically. Current rules are checked before publication.
- Backups still cancel on parent lock or backgrounding. This download policy does not extend backup, browsing, settings or PIN-change authority.
- Screen capture and recent-app snapshots are protected with Android `FLAG_SECURE`. This also prevents normal screenshots during troubleshooting.

## Build from source

Run these from the repository root. Quit an active `flutter run` using `q`
before rebuilding; native security/storage changes need a full rebuild.

```bash
flutter pub get &&
flutter analyze &&
flutter test &&
flutter build apk --debug
```

After building:

```bash
flutter devices
flutter run -d emulator-5554
```

Use the actual emulator ID reported by `flutter devices` if it differs. This uses only the local emulator; the physical tablet needs no debugging connection or access across your network segments.

## Emulator acceptance tests

1. Upgrade an MVP installation with an existing PIN. An incorrect old PIN must fail. The correct PIN plus a confirmed new PIN must migrate successfully. Relaunch and use the new PIN.
2. On a fresh emulator installation, verify that setup blocks all browsing/library access until completed. Do not clear your real tablet's data for this test.
3. Try five incorrect PINs. Confirm the cooldown persists through force-stop/relaunch and reboot. Changing the clock during the same boot must not shorten it.
4. Unlock Browse; press Home, reopen, and confirm parent access is locked. Repeat while a PIN check or unapproved save is in progress; neither may survive with parent authority. Approve a save, switch to Offline or another app, and confirm it continues while Browse/Parent stay locked. Check progress, safe cancellation from Offline/notification, and persistent success/failure feedback. Wait five minutes and confirm Parent locks without cancelling that approved job. Test notification denial, rule revocation, the overall save deadline and task/process interruption separately; no job may resume automatically or publish partial content.
5. Verify YouTube playback, search and the native approval dialog. External links, new windows, file selection, camera, microphone and location requests must not open access outside the app.
6. Approve and save a short public video. Disable connectivity **inside the Android emulator**, restart the app, then check local picture, sound, pause and seeking.
7. Block its channel ID/name or a word in its title; return to Offline and verify it disappears. Remove that block and verify it returns. Deleting a video requires parent access.
8. Save eight distinct approved videos. The ninth must be refused. Delete one as a parent and retry. Interrupt another download and confirm no partial video appears.
9. In Parent, change the PIN using the current PIN and a confirmed replacement.
   Verify the old PIN fails and the new PIN succeeds after restarting. Wrong
   current-PIN attempts must use the same persisted cooldown as unlocking.
10. Exercise the storage display with blocked, legacy and missing-file records.
    They must occupy slots in Parent while staying out of the child library.
    Deleting one must refresh the slot count. Test insufficient free space and
    interrupted-save cleanup without removing valid saved videos.
11. Follow [ENCRYPTED-BACKUP.md](ENCRYPTED-BACKUP.md) to export reviewed content
    and restore it on a separate test installation. The document picker must
    relock Parent, wrong passwords must publish nothing, and restored videos
    must require fresh approval. Existing videos and current rules must remain
    intact; applying archived rules requires a separate confirmation. Repeat
    with a rules-only archive, cancellation, low storage and an interrupted
    restore, then verify approved restored playback with networking disabled.

## PIN changes and recovery

Unlock Parent and choose **Change parent PIN**. Enter the current PIN and the
same new 6–12 digit PIN twice. Changing the PIN preserves videos and rules and
uses the existing Android Keystore key. Incorrect current-PIN attempts share
the persisted retry/cooldown limits. There is no default PIN or reset bypass.

If the app is interrupted before the change commits, the current PIN remains
valid. If the change committed just before backgrounding, the new PIN may
already be active even though the dialog could not confirm success. Reopen the
app and unlock to establish which credential is active; repeated guesses remain
rate-limited.

A forgotten PIN or lost Keystore key cannot be recovered from the app. Clearing
application data or uninstalling destroys its private videos, settings and
credentials and requires fresh parent setup. Do not use those actions as a
routine update or troubleshooting step. A separately created encrypted export,
where available, has its own password; it does not recover the original PIN or
Keystore key.

## Build a signed APK for the physical tablet

Updates must be signed with the same key as the installed app. If you already
have a release key, use the existing-key command in
[RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md); do not create another key for a
routine update. The creation example below is only for a first release.

Release builds deliberately fail until a signing key is provided. Never send the signing key or passwords into chat. Keep a secure backup of the key: future APK updates must use the same signing identity.

The repeatable build-and-evidence workflow is documented in
[RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md). It runs checks, verifies the APK
certificate against the selected existing key, and creates a detached signed
build manifest. The manual commands below remain useful for focused builds;
they do not create the complete signed evidence bundle.

Create the key once, on your own computer, using interactive prompts:

```bash
(
  umask 077
  mkdir -p "$HOME/.local/share/mits-kids-signing" &&
  keytool -genkeypair -v \
    -keystore "$HOME/.local/share/mits-kids-signing/release.jks" \
    -storetype JKS -alias mits-kids -keyalg RSA -keysize 3072 -validity 10000
)
```

If `keytool` is not on PATH, use the `bin/keytool` from your Android Studio `jbr` directory. Reuse an existing release key instead of creating another when updating a previously signed release installation.

Build in a subshell so password environment variables disappear when the command finishes:

```bash
(
  cd /path/to/MITSTUBE-Kids || exit 1
  export MITS_RELEASE_STORE_FILE="$HOME/.local/share/mits-kids-signing/release.jks"
  export MITS_RELEASE_KEY_ALIAS="mits-kids"
  read -r -s -p 'Keystore password: ' MITS_RELEASE_STORE_PASSWORD
  printf '\n'
  read -r -s -p 'Key password: ' MITS_RELEASE_KEY_PASSWORD
  printf '\n'
  export MITS_RELEASE_STORE_PASSWORD MITS_RELEASE_KEY_PASSWORD
  python3 tools/audit_dependencies.py pubspec.lock &&
  flutter build apk --release &&
  python3 tools/check_apk.py build/app/outputs/flutter-apk/app-release.apk \
    --sdk "$HOME/Android/Sdk" &&
  sha256sum build/app/outputs/flutter-apk/app-release.apk
)
```

The checker validates the built manifest, permissions, exported components,
disabled debugging, TLS and backup policies, and APK signature. Its permission
allowlist includes Internet, network-state access and playback wake locks; see
[APK-POLICY.md](APK-POLICY.md) for the dependency rationale and the checks
rejecting device-admin, home-launcher and lock-task declarations. Compare its
certificate fingerprint with `keytool -list -v` for your own key. It cannot
determine whether a custom certificate belongs to you merely from its name.

Transfer `build/app/outputs/flutter-apk/app-release.apk` to the tablet using your chosen file-transfer method. Android will reject an in-place update from a debug-signed installation to a differently signed release. An intentional uninstall removes app-private downloads and settings; do not uninstall until you are ready to lose those test data.

## Security scope and remaining limits

The app protects its own parent controls and offline library on a normally
secured Android device. Kiosk mode, device-owner/admin enforcement and device
management are permanently excluded from this project at the maintainer's
direction. The app does not control Android Settings, another browser, app-data
clearing or uninstall. These remain outside its application-level boundary.

Initial parent setup assumes a parent controls the fresh installation. No offline app can establish the adult's identity without previously provisioned trust. Rooted devices, a compromised OS or arbitrary execution inside the app are outside this boundary.

The PIN verifier uses a random salt, PBKDF2-HMAC-SHA256 (600,000 iterations), and an Android Keystore HMAC key. PIN material is never logged or persisted in plaintext. Hardware backing depends on the device; the app does not claim StrongBox protection. The app fails closed if its existing Keystore key becomes unavailable.

The app disables Android cloud backups and declares exclusions for local device transfers, private metadata and downloaded media. This does not control privileged third-party backup tools or a rooted OS. Local files use Android's private storage protections; there is no separate app-level encryption of videos.

The new backup policy prevents future inclusion; it does not delete backups created by an earlier app version.

The native media helper accepts only private offline staging paths. Its codec handling still depends on patched Android media components. Keep Android and System WebView updated.

The downloader uses the unofficial `youtube_explode_dart` extractor, without external executable or JavaScript-solver downloads. Stream availability is not guaranteed. Actual YouTube media transfer, native Keystore behaviour and codec playback require the emulator checks above.

Source rollback restores the previous code files only. It does not reverse a migrated PIN, SQLite schema or signing identity. Keep the upgraded security code after credential migration; do not use rollback as a PIN reset mechanism.

# Validation — 0.4.8+12, and 0.4.7+11 Quick Settings playback interruption

Target: Lenovo Tab One TB305FU, ZUI 17.0.10.324. The owner reported that the
previous signed 0.4.1 APK worked well on the tablet. That feedback is recorded in
[VALIDATION-0.4.1-HISTORICAL.md](VALIDATION-0.4.1-HISTORICAL.md); it predates the
touch lock, volume handling, repeat settings or experimental screen-off recovery
and does not certify them.

For 0.4.3, the owner reported that screen-off and waking worked on the Lenovo,
but the Android lock screen blocked the video. For 0.4.4, the owner reported that
the first recovery worked, but subsequent presses failed while Android remained
locked. This is limited physical-device feedback about those versions. The exact
cause of the consecutive-press failure on the Lenovo was not established.
After installing 0.4.5, the owner reported that recovery works perfectly. This
records successful use of that version; it is not a measured result for every
credential-restoration path. On 0.4.6, the owner reported that opening Quick
Settings paused the video and left the Android tablet-PIN screen. That confirmed
failure is distinct from the expected ability to open Android's system panel.
The intended 0.4.7 fix has not yet been physically verified on the Lenovo.

## 0.4.8+12 offline pictures and autoplay

Version 0.4.8 adds picture cards to Offline and **Play next video
automatically**; **Repeat this video** is unchanged. Measured on 2026-10-03:

- 259 Flutter unit and widget tests passed (26 new), with analysis clean. The
  signed release workflow ran them again together with the Python tool tests,
  native Kotlin policy checks, Dart and Android dependency audits (no findings)
  and APK policy checks, and verified the signed build manifest.
- On the Android 15 (API 35) Pixel Tablet emulator, 2560×1600 x86_64,
  `tools/test_android.sh` passed all six native acceptance tests. They include
  the two new checks: pictures made from saved files by the real Android
  decoder (bounded 320×180 JPEGs, shown on each card), and real playback that
  continues touch-locked into the next saved video and stops after the last.
- A visual check of the validation build showed the picture grid, both
  playback switches, and autoplay through three saved videos while
  touch-locked, ending with "No more videos to play next." The app's
  `FLAG_SECURE` blanks system screenshots, so frames were captured from the
  Flutter engine using the Skia renderer. During the switch, the finished
  video's picture went dark behind the spinner on this emulator.
- The exact signed 0.4.8 APK installed fresh on the emulator, launched without
  errors and was then removed. No earlier release was installed there, so an
  in-place update over 0.4.7 was not exercised.
- On this workstation's 7.2.7 kernel, emulator 37.1.11 crashed during boot with
  software rendering. It booted with `-gpu host`.

Not tested: the Lenovo tablet, real YouTube saves of different videos, an
in-place update from 0.4.7, or autoplay after screen-off recovery while
Android is locked. Follow the new sections of [TABLET-TEST.md](TABLET-TEST.md).

## Changed behavior

Version 0.4.7 distinguishes a temporary loss of window focus to Android's system
panel from actually pausing or leaving the video activity. An already-playing,
touch-locked video continues during the former. Native handling can retain an
existing permission to show that same locked player above Android's lock screen
while the screen is interactive and the activity remains resumed but unfocused.
It does not grant that visibility to a new player, a paused video or another app.
Opening the panel alone should therefore no longer stop the video or leave the
Android PIN screen after a successful screen-off recovery.

The matching current-cycle acknowledgment may finish an already-successful
recovery handoff while a panel holds focus. Stale acknowledgments, a missing
acknowledgment and an in-flight wake retain their original deadlines. Losing
focus cannot acquire permission to show a different player above the lock screen.

Outside the separately bounded screen-off recovery path, an actual activity pause
still has cleanup of at most one second. Home, stop, explicit unlock and leaving
the player revoke the existing visibility. Hidden/paused Flutter lifecycle
states still pause playback. Opening Settings or another
app from the panel restores Android's normal credential protection when required.
Parent authority remains locked, and an already-paused video is not started by
dismissing a panel. These are the intended behaviors to verify on the tablet,
not a claim of physical acceptance.

The player offers a top-right touch lock with a continuous two-second hold to
unlock. While locked, app controls, seeking, settings, focus actions and Back
are blocked. Version 0.4.6 also intercepts in-app drag gestures immediately,
including those that could otherwise reach an ancestor gesture handler and
dismiss the player. Moving more than 12 logical pixels cancels an unlock hold
even within the target; a second touch on the surrounding shield also cancels it.
The lock remains reachable, including on a playback error. Native
volume handling applies only to a locked, resumed, focused activity and releases
when leaving the player/app. Power/Home/system actions remain under Android's
control; there are no new permissions, overlay services or device-management
features.

While touch-locked, scoped native immersive presentation requests hidden status
and navigation bars. It restores the previous visibility/behavior on explicit
unlock or when leaving the activity, and reapplies when returning to the player
if it is still locked. Revealing transient bars or the notification panel does not
unlock app controls or trigger repeated attempts to collapse the panel. Android
retains control of its edge gestures, notification panel, Quick Settings and
Home; this app's touch lock does not disable them. No app pinning, kiosk mode,
device management, accessibility service, root access or blanket system-gesture
exclusion is added.
See [Android's immersive-mode guidance](https://developer.android.com/develop/ui/views/layout/immersive)
for the user-revealable system bars and [gesture-navigation limits](https://developer.android.com/develop/ui/views/touch-and-input/gestures/gesturenav).

The unlocked timeline now shows an actual frame from the saved local video with
the proposed time while dragging. Releasing commits the seek and resumes only
if playback was running before the drag; paused playback stays paused. Locking
or backgrounding cancels the scrub and invalidates delayed results, so old
callbacks cannot seek or resume playback. Extraction is local and requires no
new permissions, dependencies or network requests. Frame decoding can select a
nearby scene frame rather than the precise timestamp; it is a preview, not a
replacement for the player's final seek.

In-player settings expose **Repeat this video**, defaulting to off and persisted
per video ID. The local video controller applies native looping. The repeat
preference is a convenience setting, not content approval or Parent authority.
Existing approval/rule/file-integrity checks and pause on actual backgrounding
remain. The new focus-only exception does not permit playback in another app.

Parent settings retain **Recover from accidental screen-off**, clearly
marked experimental and off by default. The existing setting/key is retained;
upgrades preserve its previous enabled or disabled value and add no second toggle.
The choice saves automatically for this tablet under live Parent authority; it is
separate from content rules and the per-video repeat preference. Unreadable or
uncertain preference state is treated as off. Failed or interrupted writes cannot
expose an unconfirmed enable to playback through the shared preference cache.

When enabled, recovery is limited to the same video that was already playing
and touch-locked immediately before the screen-off. It does not apply to paused
or unlocked playback, another app, or after pressing Home. Android still owns
the power action: the screen may go dark before a bounded attempt to wake it.
The touch-locked video can remain visible above the Android lock screen, as
introduced in 0.4.4. Watching the same locked video need not require the screen PIN.
Holding the playback lock to unlock, or leaving the player, restores the normal
Android lock screen before other controls become usable if Android is still
locked. The Android credential remains required under Android's normal policy;
no credential is removed, changed, or automatically dismissed. Parent authority
remains separate and locked.

Version 0.4.5 tracks confirmed screen-off/on cycles while the player remains
eligible. Listening continues across successful recoveries, including when Android
remains locked without the expected activity lifecycle callbacks. Each cycle has
its own identity; stale completions cannot resume or disarm a later cycle. Each
confirmed new screen-off gets at most one bounded wake attempt, and duplicate
notifications do not create extra attempts. Successful recoveries no longer
consume a five-second cooldown or a three-per-minute quota. Failed or timed-out
attempts do not retry automatically in a loop.

Each wake request retains its 1.5-second bound, and the recovery and handoff
windows remain at most three seconds. A later screen cycle does not extend the
earliest still-unacknowledged handoff deadline. Only failed or timed-out attempts
are limited to three within 60 seconds; successful recoveries do not consume
that failure allowance.

No new permission, device administration, root access, system-wide overlay or
shutdown/restart prevention is added. If an attempt fails, the user can manually
wake the tablet, complete any Android unlock, unlock playback and press Play.
That does not count as a successful automatic recovery. The existing Parent
toggle and consecutive recovery behavior are retained in 0.4.7; temporary
focus-loss handling after recovery is the new change. Consecutive presses and
return to Android's credential lock remain release regression checks even after
the owner's successful 0.4.5 feedback.

The 0.4.1 bounded approved-download foreground service, five-minute Parent gate,
backup cancellation, database schema 3 and private library remain in place.

## Automated evidence and limits

The release workflow captures Dart analysis, the complete Flutter unit/widget
suite, Python APK/signature checks, pure Kotlin checks and dependency audit
results beside the APK. It verifies the production APK's compiled policy and
signature and signs the source snapshot and build-evidence manifest with the
retained app key. Consult the final release directory for actual measured counts,
timestamps and hashes. Tests use fake player/platform backends where Android
runtime operations cannot run on the host; they do not prove physical key behavior.

Player tests cover touch/seek/Back blocking, deliberate unlock and cancelled
holds, loop preferences and their storage failures, lifecycle/disposal and the
native bridge. New recovery checks cover Parent preference persistence, failed
writes and cache compensation, session expiry, concurrent access, player state
eligibility, end-of-video and delayed-play recovery races, and bounded native
recovery policy. The native key policy is tested independently from Android's
key delivery. The final release compiles the actual activity integration.

The earlier 0.4.6 scoped immersive policy had 49 passing host Kotlin checks,
including notification-focus transitions, repeated requests, Home followed by late
requests, resumed focus, exit and failed restoration. Its Android wrapper also
compiled separately against API 36. These checks verify policy and compilation;
they do not measure Lenovo system-bar behavior. Final counts for the complete
0.4.7 suite and signed build belong in the release evidence, not an inferred
physical-device result.

Earlier host-rendered portrait and landscape lock layouts and the repeat-settings
dialog were visually inspected using the production dark theme and a fake video
backend. Those captures check layout and labels, not video decoding, the new
scene-preview layout or physical key input.

For 0.4.6, the actual preview timeline was separately captured and visually
inspected in portrait and landscape using the production dark theme and an
injected synthetic scene. The image, timestamp and seek control fit both layouts.
Those host captures verify preview layout and contrast, not Android frame decoding
or Lenovo gesture handling.

**No emulator or physical-tablet acceptance is claimed for 0.4.7.** The owner's
successful 0.4.5 recovery report does not validate the Quick Settings fix, and the
0.4.6 interruption remains recorded above. Follow
[TABLET-TEST.md](TABLET-TEST.md) to check the update preserves the existing PIN
and library, repeat visibly/audibly restarts at the end, the lock prevents stray
input, Lenovo delivers ordinary volume presses to the focused app, and optional
screen-off recovery works only in the intended playing-and-locked case. Verify
the same Android and Parent PINs still work, the locked video can remain visible
without a screen-PIN prompt, and Android's normal lock returns before player
unlock or departure exposes other controls. Test at least five consecutive Power
presses in the same locked session with six-second spacing after playback returns,
then three more at one-to-two-second spacing after picture and sound return. Do
not enter credentials, reopen the player or toggle recovery between presses.
Check Home cancellation, off/paused/unlocked controls and offline repeat. System
shortcuts remain available. Also distinguish blocked in-app drags from Android's
accessible notification/Quick Settings panel, verify moving and multiple-finger
unlock cancellation, and check local scene previews in both seek directions,
paused and playing, portrait and landscape, with Wi-Fi off. Locking or leaving
during a scrub must cancel it without a delayed seek or resume.

For the 0.4.7 regression, first recover from screen-off while the same video is
playing and touch-locked above Android's lock screen. Open and dismiss both the
notification panel and expanded Quick Settings after one, five and 20 seconds,
repeating without credentials, player unlock or reopening the video. Sound should
continue and the same locked picture should return without an Android PIN prompt.
Then verify Home, Settings navigation and explicit player unlock restore Android's
credential protection where required, and confirm paused/ended video does not
start merely because a panel closes. Repeat in both orientations and offline,
then run the existing five-plus-three recovery and scene-preview checks.

Earlier measured emulator checks of downloads/offline playback, Keystore/PIN and
encrypted backup are retained in [VALIDATION-0.4-HISTORICAL.md](VALIDATION-0.4-HISTORICAL.md).

## Signing and delivery

Package: `com.example.mits_kids_youtube`; version 0.4.7/code 11; minimum API 26.
The universal APK contains ARM64, ARMv7 and x86_64. It reuses the same app signing
certificate as the owner's tested 0.4.1 APK:
`f3f945b2ae802bfba2d000ccb0a560ed18477bd725ab14de07752ad5037615ff`.

Install as an update, preserving app data. On an unexpected signature conflict,
retain the current app and report the error instead of uninstalling/clearing data.
Only the APK/checksum need transferring; private keys/passwords stay on the
workstation. See [RELEASE-EVIDENCE.md](RELEASE-EVIDENCE.md) for retained-key builds.

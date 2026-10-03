# Lenovo tablet test — MITS Kids 0.4.8+12

Target supplied by the owner: Lenovo Tab One TB305FU, Lenovo ZUI 17.0.10.324.
The owner reported that 0.4.1 worked well. On 0.4.3, screen-off and waking worked,
but Android's lock screen blocked the video. On 0.4.4, the first recovery worked,
but subsequent presses failed while Android remained locked. The exact cause on
the Lenovo was not established. After version 0.4.5 changed consecutive recovery
handling and removed the old limit on successful recoveries, the owner reported
that it works perfectly. On 0.4.6, the owner reported that opening Quick Settings
paused playback and left the Android tablet-PIN screen. Version 0.4.7 is intended
to keep the already-playing, touch-locked video available when a system panel
temporarily takes focus, including after screen-off recovery. The fix is not
yet verified on the tablet. Android's normal credential lock must still return
when unlocking the player or leaving for Home, Settings or another app.
Version 0.4.8 adds pictures to the Offline list and **Play next video
automatically**; see the sections near the end.

## Install over the tested version

1. Upload `MITS-Kids-YouTube-0.4.8.apk` and optionally `SHA256SUMS` to your chosen
   transfer location. Keep the private signing folder on the workstation.
2. Download/open the APK on the tablet and accept the update. It uses the same
   package and signing key as the existing installation with a higher version
   code. Existing videos, Parent PIN, Android screen PIN, content rules and repeat
   choices should remain in place; do not uninstall or clear data. The recovery
   switch keeps its saved value, including an enabled choice from 0.4.3.
3. If Android reports a signature/incompatible-app error, retain the existing app
   and send the exact message. No infrastructure CA certificate is needed.

## Touch lock and volume

1. Open a saved video and start playing. Adjust the volume to a comfortable level
   before locking. Tap the lock at the top right.
2. Tap the picture, play/pause, restart, seek bar, settings and Back. Drag the
   picture and controls up, down and sideways, including a gesture that normally
   slides or dismisses the video. None should change playback, move the app's
   player off screen or exit it. A quick tap on the lock should not unlock.
3. Hold the lock continuously for two seconds. The progress ring should complete
   and the controls should unlock. Lock again, start a hold and move the finger
   across the lock by more than 12 logical pixels, even without leaving its
   outline: the hold should cancel. Releasing early, moving off, or touching the
   surrounding locked area with a second finger must also cancel it. Waiting
   after cancellation must not unlock; begin a fresh deliberate hold to unlock.
4. Lock again. Ordinary volume up/down presses should leave volume unchanged
   while the player is foreground and focused. Unlock and confirm they work again.
5. Repeat in portrait and landscape. Check the unlock control remains reachable.
6. Use Home/switch apps, then return. Volume should work outside the app. Playback
   should pause on leaving; the touch lock remains when returning. Hold to unlock,
   press Play and lock again. Power and Android system controls remain available.
7. While locked, check that Android's status and navigation bars hide where the
   device permits. Swipe from the top edge. Android may reveal its bars,
   notification panel or Quick Settings; this is an Android system gesture, not
   an unlocked app control. Dismiss the panel and confirm the player remains
   touch-locked and a video that was already playing continues. Try an ordinary
   drag within the video again: it must remain blocked. The app must not
   repeatedly collapse the Android panel for you.
8. Unlock or leave the player and confirm the bars return to their previous
   presentation. Re-enter and lock again in both orientations. Home, app
   switching and Android's system navigation must remain available.

This is an in-app touch lock. Android handles the power button, system navigation,
notification shade and system button combinations; this app's touch lock does
not disable them. It does not use device administration, kiosk mode, accessibility
services, root access or a system-wide overlay. Lenovo-specific physical button
handling must be checked on this tablet.

## Quick Settings after screen-off recovery

1. Keep Android's secure screen lock enabled and enable **Recover from accidental
   screen-off** in Parent. Use a saved video longer than two minutes or turn on
   **Repeat this video**. Leave Parent, start the video and touch-lock it.
2. Briefly press Power and wait for the same picture and sound to return above
   Android's lock screen. Do not enter either PIN or unlock playback.
3. Pull down the notification panel or Quick Settings without opening another
   app. Leave it open for **one second**, then dismiss it. Sound should continue
   while the panel is open; after dismissal, the same video should be visible
   and playing with touch lock still on, without an Android screen-PIN prompt.
4. Repeat with the panel open for **five seconds**, then **20 seconds**. Repeat
   all three durations without reopening the player, entering a PIN, changing
   recovery or unlocking playback. Test both the notification panel and expanded
   Quick Settings. Record the duration and result of each attempt.
5. Repeat in portrait and landscape and with Wi-Fi off. Android may obscure the
   picture while its panel is open; the check is that sound continues and the
   locked video returns when the panel closes. No new playback should start if
   the video was already paused or had ended. Also repeat an ordinary panel
   opening with recovery off; the existing video should still continue if it
   was playing and touch-locked before opening the panel.
6. In a recovered session while Android remains locked, open Quick Settings and
   choose its Settings button or another action that leaves for another app.
   Expect Android's normal credential protection before using that other app.
   Repeat with Home/app switching: playback should pause, the recovered video
   must not remain above other apps, and Android's lock should return if required.
7. Return to the player after completing Android's normal unlock if needed.
   Playback should remain paused after actually leaving the app. Hold to unlock
   and press Play deliberately. Parent and Browse must still require the Parent
   PIN; both the Android credential and Parent PIN must be unchanged.
8. In another recovered session, dismiss the panel and then hold the playback
   lock for two seconds. If Android is still locked, its normal credential
   screen should return before unlocked player controls become usable.
9. Repeat the five-plus-three Power-press sequence below after the panel checks,
   then verify local scene previews and repeat playback. If opening a panel
   still pauses the video or leaves the Android PIN screen, report which panel,
   its duration, whether sound stopped before or after dismissal, and whether
   you selected an action that opened another app.

The intended fix preserves the same locked video during a temporary panel
opening. It does not block the panel, automatically dismiss Android credentials,
or add app pinning, kiosk mode or device management. Actual Android activity
pauses and departures retain bounded cleanup and normal lock restoration.

## Scene previews while seeking

1. Turn Wi-Fi off and open a saved video with changing scenes. Keep the player
   unlocked. Start playback, then drag the timeline forward and backward. A small
   image from that local video and the proposed time should follow the seek;
   it must not navigate to YouTube or require a network connection.
2. Release at a recognisable scene. The player should seek to the selected time
   and resume because it was playing before the drag. The preview disappears.
   A nearby decoded frame may differ slightly from the exact displayed time.
3. Pause playback and repeat a forward and backward drag. The image/time preview
   should still work, and releasing should seek while keeping playback paused.
4. Start another drag and, with another finger, tap the playback lock. The drag
   and preview should cancel. Continuing or releasing the original finger must
   not seek or restart playback while locked. A delayed preview must not reappear.
5. Unlock, start a drag and press Home or switch apps. Return to the player:
   the preview should be gone, and late work from that drag must not seek or
   resume playback. Press Play deliberately to continue.
6. Repeat with rapid forward/backward changes and in portrait and landscape.
   Check the thumbnail, time and timeline fit on screen, and that releasing uses
   the current selection rather than an older thumbnail request. Repeat a seek
   while paused after rotating the tablet.

Scene previews use the existing private video file. There are no new permissions,
dependencies or network requests for them. Record the video and time if preview
extraction fails or the scene does not match the selected area.

## Consecutive recovery while Android remains locked

1. Unlock Parent and find **Playback → Recover from accidental screen-off**.
   Confirm it is marked **Experimental** and explains that the video may remain
   visible while the tablet is locked. It saves automatically, separately from
   **Save settings** for content rules. A new installation defaults off; an
   upgrade retains the previous choice. There is no second recovery switch.
2. With recovery off, play and touch-lock a video, then briefly press Power.
   The tablet should stay asleep normally. Wake it manually, complete the normal
   Android screen unlock if required, hold the playback lock to unlock, and press
   Play again.
3. Enable recovery in Parent, leave and reopen Parent to confirm it stayed on,
   then lock Parent access. Use a saved video longer than two minutes, or enable
   repeat so it will not end during the test. Keep Android's secure screen lock
   enabled. Open the video, press Play and touch-lock it.
4. Perform **five consecutive short Power presses in the same player session**.
   After each press, wait for picture and sound to return, then wait six seconds
   before the next press. Check every recovery, including presses 2–5: the same
   video should return with sound, touch lock still on, and no Android screen-PIN
   entry simply to keep watching. Do not enter either PIN, unlock playback, reopen
   the player, change the preference, or press Home between these five attempts.
   Parent and all other app controls must remain locked throughout.
5. Without resetting or unlocking that session, try **three more short presses**,
   this time waiting **one to two seconds after picture and sound return** before
   each next press. Successful recovery should not stop at the old five-second
   cooldown or three-per-minute limit. Wait for a complete return before pressing
   again; this checks separate screen-off cycles, not multiple presses while dark.
6. After the last recovery, hold the playback lock for two seconds. If Android
   remains locked, expect its normal PIN/pattern/password screen before unlocked
   player controls become usable. Confirm the same Android credential still works.
   In a separate recovered session, leave the player and confirm Android's normal
   lock also returns before other apps or app controls can be used. If Android
   considers the device already unlocked, its normal behavior applies.
7. After completing Android's normal unlock, confirm Parent and Browse still
   require the Parent PIN. Recovery must not change either PIN, grant Parent
   access, or expose another app while Android remains locked.
8. Disable recovery and repeat a screen-off press: the app should not attempt to
   wake or show the video above Android's lock screen. Re-enable it for the
   remaining checks.
9. With the player unlocked and playing, press Power: no recovery should occur.
   Repeat with the video paused and touch-locked: it should also remain asleep.
10. Start playing, touch-lock, press Home, then Power. Recovery must not return
    from Home or another app. If Android is still locked, its normal lock screen
    must remain in control. Volume and system controls should work outside the
    player as usual.
11. If any recovery fails or times out, record the press number and what remains
    visible before manually waking or unlocking. It must not repeatedly wake by
    itself: each new screen-off gets at most one bounded attempt. A manual restart
    of playback is recovery from a failed test step, not a pass for that step.
    Only failed or timed-out attempts are limited to three within 60 seconds;
    successful recoveries do not use that allowance.
12. With Wi-Fi off and **Repeat this video** enabled, repeat the five-press sequence.
    Confirm it remains the same local video and repeats with picture and sound.
    Then disable repeat and confirm the video ends normally.
13. Confirm Power's system menu, shutdown and restart remain available. Restarting
    must not reopen a video or resume an earlier recovery attempt automatically.
14. Turn recovery off if it is inconsistent or unwanted. This does not require
    new permissions, device administration, kiosk mode, root access, accessibility
    services or a system-wide overlay. Android's credential lock stays enabled.

For presses 1–8, record the press number, time since the previous return, how long
the screen stayed dark, whether picture and sound resumed, whether the touch-lock
icon remained, and whether Android requested a credential. This distinguishes a
first-only recovery from a failure at a particular timing or later press count.

## Repeat this video

1. With the player unlocked, tap the settings gear and enable **Repeat this video**.
2. Close settings, play and seek near the end. Confirm the same video restarts
   with picture and sound. Locking should not stop repeat.
3. Unlock, leave the player and reopen the video. Repeat should still be on.
4. Open another video: its repeat setting is independent and defaults to off.
5. Disable repeat, seek near the end and confirm playback finishes once.
6. Repeat the playback checks with Wi-Fi disabled.

## Offline pictures

1. With Wi-Fi off, open Offline. Each saved video should show a picture from that
   video. On the first visit after updating, pictures may appear one at a time;
   later visits should show them straight away.
2. Check each picture is recognisable rather than blank. Record any video whose
   card keeps the film-strip placeholder.
3. Open a video while pictures are still appearing, then drag the timeline:
   scene previews must still work. Go back and confirm the remaining pictures
   appear.
4. Save a new video: its picture should appear in Offline after the save
   completes. Delete a video in Parent: its card should disappear.
5. Check portrait and landscape. Cards should sit in columns across the screen
   with titles readable and nothing clipped.

## Play next video automatically

1. Open a video, tap the settings gear and turn on **Play next video
   automatically**. Leave **Repeat this video** off.
2. Play, seek near the end and touch-lock the player. When the video ends, the
   next video in Offline's order should start by itself with picture and sound.
   The touch lock should stay on, volume keys stay locked and system bars stay
   hidden.
3. Let the last video in Offline finish. Playback should stop with "No more
   videos to play next."
4. Turn on **Repeat this video** for one video. It should keep repeating and not
   move on.
5. Leave and reopen the player, and open another video. Autoplay should still
   be on for every video. Repeat with Wi-Fi off.
6. With screen-off recovery on, let a video end after a recovery while Android
   is still locked. Android's lock screen should return as before, without the
   next video starting above it.

## Download regression (optional)

Approve a short public YouTube video, then lock Parent or switch apps briefly.
The approved save may continue for up to 30 minutes, with notification progress
and Cancel when permitted. Parent remains locked. Removing the app from Recents,
force-stop, process death or reboot interrupts the save with no automatic resume.
No incomplete video should appear as playable. Backup/export still cancels on
Parent lock/background under its five-minute session boundary.

Please report the failing step and exact error, and the Android version from
About tablet if available. No physical-tablet ADB connection is required.

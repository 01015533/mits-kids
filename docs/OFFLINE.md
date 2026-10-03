# Offline library — application version 0.4.2+6

A parent unlocks Browse, reviews a video, selects **Approve & save**, and confirms
the video's title and channel. The app downloads directly from YouTube to private
local storage; no home server or offline-service address is required.

- Maximum eight saved entries, including legacy, blocked and unavailable entries.
  One download can run at a time.
- Up to 720p AVC/AAC MP4 and 1 GiB of downloaded source data per video.
- A combined stream is preferred. Separate video/audio tracks are combined by
  Android MediaExtractor/MediaMuxer in the private offline staging directory.
- Free-space checks reserve 128 MiB beyond the expected transfer, plus another
  copy of the media and 16 MiB of mux overhead for separate audio/video tracks.
  Available space is rechecked before combining tracks. Other apps can still
  consume storage during a transfer; failure leaves no playable partial entry.
- A completed entry stores parent approval, channel identity and a SHA-256 digest.
- Children see only approved videos allowed by current rules, with a private
  file of the expected size. The child count says how many videos are available
  to watch. The player checks rules again and verifies the entire local file
  hash before opening it.
- Parent shows all occupied slots, measured saved-file bytes and current tablet
  free space. Blocked, earlier unapproved and missing/damaged entries are labeled
  for review. Unavailable records remain manageable until a parent deletes them;
  listing the library never silently deletes records.
- No remote thumbnails, network fallback or WebView is needed for offline playback.
- Offline shows each available video as a picture card. The picture is a frame
  from the saved file about a quarter of the way in, or a later scene when that
  frame is nearly blank, made by the same private decoder as scene previews.
  Pictures are only made while Offline is the visible screen, kept in the app's
  cache, made again if Android clears it, and removed after a video is deleted.
  They are not part of backups and are never fetched from YouTube.
- Parent access locks on leaving the app, selecting Offline, and after five
  minutes. Browse is removed and Parent controls stay behind the PIN.
- Work which has not received explicit approval is cancelled on lock. Once a
  parent confirms the title/channel, that exact save may continue after lock or
  while switching apps. It cannot approve another video or reopen Parent.
- Offline shows an approved save's progress and a Cancel action without needing
  a PIN. The result remains visible after Browse has closed. Android also offers
  a progress/cancel notification when notifications are allowed; denying the
  notification prompt does not grant access to Parent or cancel the approved job.
- The complete save has a 30-minute limit, including preparation and finishing.
  Removing the app's task, force-stopping, process death or restarting the device
  stops it; there is no automatic resume or new approval. Retry after unlocking.
- Current content rules are checked again before publishing the saved video.
  Explicit cancellation never makes partially downloaded media playable.
- Encrypted backup/export/restore still cancels when Parent locks. The approved
  download allowance does not apply to backups, PIN changes or browsing.
- Recognized partial staging files and unreferenced app-named MP4s are cleaned
  before a save. This recovers a file left by process death between final rename
  and database commit. Referenced files, unknown filenames and symlink targets
  are preserved. A partial file never becomes child-playable.
- Old downloads remain on disk but need deletion and a newly approved download
  before they are available to children. Manage downloads from Parent.
- Uninstalling or clearing application data removes downloads and settings.

## Playback controls

Tap the top-right lock to prevent accidental in-app taps, play/pause, scrubbing,
settings changes and Back. Only the lock remains actionable; hold it continuously
for two seconds to unlock. A progress ring shows the hold. Releasing early or
moving away cancels the hold. The lock is a playback convenience, not Parent
authentication or device management.

While the locked player is foreground and focused, volume up/down/mute events
delivered to the app are consumed. Normal volume handling resumes on unlock,
player exit or leaving the app. Power, Home, Recents, notification shade and
system button shortcuts remain controlled by Android. This app cannot prevent
the power button turning the tablet off. No accessibility service, overlay
permission, device administrator or root access is requested.

Android references: [activity key dispatch](https://developer.android.com/reference/android/app/Activity#dispatchKeyEvent(android.view.KeyEvent))
and [system power-key handling](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/policy/PhoneWindowManager.java).

Open the player's settings gear and enable **Repeat this video** to replay the
same local file when it ends. The preference is saved per video ID, defaults to
off, and applies again when reopening that video. It does not approve new media
or change content rules. Lock the player after choosing repeat. Leaving the app
still pauses playback; unlock and press Play after returning if needed.

Enable **Play next video automatically** in the same settings to continue with
the next video in Offline's order when one ends. It is one choice for all videos
and defaults to off. The next video must pass the current content rules and a
full file hash check before it plays; blocked videos are never opened, damaged
files are skipped, and playback stops after the last video. **Repeat this
video** takes priority. The next video opens in the same player, so the touch
lock, volume-key handling and hidden system bars continue. Using a player control,
opening settings or leaving the app while the next video is being prepared keeps
the finished video instead, and returning to the app never starts it. After a
screen-off recovery while Android is still locked, a finished video returns
Android's lock screen as before, so autoplay does not continue past it.

YouTube uses an unofficial extraction path; public-video availability can change.
Actual media transfer and Android codec playback require an Android device check.
Follow [SECURITY-UPDATE.md](SECURITY-UPDATE.md) for acceptance checks and deployment.

Local MP4 import, kiosk mode and device management are outside the project scope;
see [ROADMAP.md](ROADMAP.md).

# Release APK permissions and platform scope

The release checker permits these six Android permissions and rejects every
other requested Android permission:

| Permission | Reviewed use |
| --- | --- |
| `INTERNET` | Parent YouTube browsing and the exact parent-approved download. |
| `ACCESS_NETWORK_STATE` | The pinned Media3 playback dependency observes network state. This permission cannot change network settings. |
| `WAKE_LOCK` | Media3 local playback; a partial wake lock bounded to the approved download's remaining 30-minute lifetime. |
| `FOREGROUND_SERVICE` | Keeps one approved download running with an Android notification when Parent locks or the app backgrounds. |
| `FOREGROUND_SERVICE_DATA_SYNC` | The exact `dataSync` service type used for the approved network transfer. |
| `POST_NOTIFICATIONS` | Progress and Cancel notification; requested only after the approved job has started. Denial does not cancel that job. |

The current `video_player_android 2.12.2` dependency uses Media3 `1.9.2` for both
debug and release builds. The Media3 manifests declare the two playback
permissions above. Its pinned [ExoPlayer implementation](https://github.com/androidx/media/blob/1.9.2/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/ExoPlayerImpl.java)
selects `WAKE_MODE_LOCAL` by default when its stuck-playback checks are enabled;
its [network observer](https://github.com/androidx/media/blob/1.9.2/libraries/common/src/main/java/androidx/media3/common/util/NetworkTypeObserver.java)
uses Android connectivity state. Preserve those reviewed dependency permissions
instead of stripping them from a player that expects them.

The checker also permits app-namespaced permissions only when the same manifest
defines them with signature protection, for AndroidX's non-exported receiver
support. It still rejects camera, microphone, location, storage, installation,
other foreground-service types and other unreviewed permissions. The final merged APK,
including dependency additions, must pass `tools/check_apk.py`.

The three new download permissions require both exact reviewed components:
`com.mitskids.offline.ApprovedDownloadService` and
`com.mitskids.offline.DownloadCancelReceiver`. Both must be explicitly
non-exported and have no intent filters. The service must declare only `dataSync`;
its task-removal callback cancels work, so `stopWithTask` is explicitly false.
The notification Cancel action uses an explicit immutable PendingIntent for the
current opaque job ID. No boot receiver, scheduler, persistent work record,
sticky restart, automatic retry or battery-optimization exemption is added.

Android requires a foreground start and the correct declared service type;
the plugin validates fresh parent authority before starting and calls
`startForeground` before acknowledging the job. Later parent locking cannot
grant new approval or change that job. See Android's
[foreground-service launch requirements](https://developer.android.com/develop/background-work/services/fgs/launch)
and [data-sync service type](https://developer.android.com/develop/background-work/services/fgs/service-types#data-sync).
Notification permission denial leaves foreground services allowed but hides their
notification-drawer controls; Android still exposes them in its task manager.
The app retains its own Cancel control. See
[notification permission behavior](https://developer.android.com/develop/ui/compose/notifications/notification-permission).
The app's 30-minute limit is stricter than Android's data-sync allowance and it
also stops on Android's timeout callback. See
[foreground-service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout).

Kiosk mode, home-launcher replacement and device administration are excluded
from this project. The checker rejects device-admin component permission or
metadata, a HOME launcher category and enabled lock-task modes. This manifest
gate complements code review; it is not a complete analysis of application code.

Run the checked-in APK policy regression tests with:

```bash
python3 -m unittest discover -s tools/tests -p 'test_*.py' -v
```

`tools/tests/native/` includes the original derivation/backoff checks and private
offline-directory path tests. Compile each main separately with the corresponding
Kotlin helpers. JVM checks cannot verify Android Keystore, `StatFs`, lifecycle
callbacks or codec behavior; those remain emulator/device checks.

# Using encrypted backups

This feature is implemented as part of release preparation. See
[VALIDATION.md](VALIDATION.md) for the checks actually completed before relying
on an exported archive. The [design record](ENCRYPTED-BACKUP-DESIGN.md) describes
its format and security boundary.

## Export

1. Unlock Parent and choose **Encrypted backups**.
2. Choose **Choose backup destination**. Android's document picker lets you
   select a destination; it may be a cloud provider. The app does not request
   broad storage access.
3. Returning from the picker locks Parent as usual. Unlock again, then reopen
   **Encrypted backups** to continue with the selected document.
4. Choose eligible reviewed videos and whether to include current content
   rules. Earlier unapproved, blocked and unavailable copies cannot be exported.
5. Enter and confirm a separate password of at least 16 characters, then choose
   **Export encrypted backup**. A long multiword password is easier to retain.
   Keep it securely: the app cannot recover a forgotten backup password.
6. Keep the app open and wait for the success message. Cancelling, leaving the
   app or reaching the parent-session limit cancels the operation. A failed
   export may leave an incomplete provider document; delete that incomplete
   document if the provider could not remove it.

An export contains selected video data and optionally content rules. It contains
no parent PIN, PIN verifier, Android Keystore key, cooldown data, browser session
or application signing key. Exporting only rules is supported.

## Restore and review

1. Complete normal parent setup on a fresh installation, or unlock the existing
   Parent screen. Choose **Encrypted backups**, then **Choose backup to restore**.
2. Select a MITS backup, unlock Parent again after the picker returns, and reopen
   **Encrypted backups**. Enter its separate password and choose **Open backup
   for review**.
3. The whole archive must authenticate before any video can be approved. Review
   the title and channel, and use **Review restored video** for a private local
   preview. Previous archive approval does not approve it for this installation.
4. Select the videos you approve and choose **Approve & restore**. Current rules
   still apply. Existing videos are preserved; duplicates are not replaced and
   videos are never evicted to make space. The library's eight-slot limit applies.
5. Current rules remain active after videos are restored. If the archive includes
   rules, **Review archived rules** compares them with the current rules.
   **Apply archived rules** is a separate choice; **Keep current rules** leaves
   the existing rules unchanged. Archived rules may allow content now blocked.
   You can also skip adding videos and review the archived rules only.

Restoring never changes the parent PIN or bypasses parent authentication. A
forgotten backup password cannot recover the app PIN, and a known app PIN cannot
recover the archive password. This is a MITS archive restore flow; there is no
general MP4 import feature.

## Interruptions and storage

The app keeps a free-space reserve and stages a restore in private storage.
Failure, cancellation or a parent lock removes uncommitted plaintext; reopening
the selected archive requires parent access and the password again. Saved videos
already present are preserved. Available slots and actual free space are shown
in Parent; delete saved copies deliberately there if more room is needed.

Large archives may exceed the five-minute parent session. Do not treat an
incomplete operation as a usable backup. Test a completed export by restoring it
on a separate test installation before deleting your only original copies.

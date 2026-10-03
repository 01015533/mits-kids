# Encrypted backup and restore — implementation design

Status: design accepted for implementation. Native archive/SAF code, the Dart backup service and parent-only review screens have been added. This document records the format and intended controls; it is not evidence that every acceptance check has passed. See `VALIDATION.md` for measured results and `ENCRYPTED-BACKUP.md` for the user flow. The recorded emulator round trip passed with Android's Downloads provider; other providers, larger archives, the exact final signed APK and the target tablet still require acceptance.

## Scope and boundary

Application version 0.4.2+6 uses archive format version 1 and local database schema
3. These are independent version identifiers; the historical 0.3.0+3 update ZIP
does not contain the backup feature or schema-3 restore recovery.

A parent can export approved, intact YouTube downloads and content rules to one encrypted archive, and can restore selected entries into available library slots. Android cloud backup and device-transfer backup stay disabled. There is no general MP4 import, device-management profile, kiosk mode or authentication reset.

Archives contain video bytes, their SHA-256 digests and required YouTube metadata, plus an optional rules snapshot. They never contain the parent PIN/verifier, Android Keystore material, parent-session tokens, attempt/cooldown state, app-signing keys, cookies or WebView data. Restoring onto a fresh installation first requires normal parent setup; restoring onto an existing installation preserves its current parent credential.

The Android package/signer controls installation updates. It is not a backup encryption key, is not restored as app data, and cannot be used to bypass an incompatible APK signature. A backup password cannot recover a forgotten parent PIN. A forgotten backup password makes that archive unrecoverable.

Authenticated encryption establishes possession of the backup password and detects modification. It does not prove that a purported uploader supplied the media, or that a person who knows the password used an unmodified exporter. Restored content therefore requires fresh parent review and approval. Canonical YouTube metadata is a required format constraint, not a cryptographic proof of origin.

## Implemented encryption construction

- The Android dependency is Google Tink `tink-android:1.23.0`. A newly generated Tink `AES256_GCM_HKDF_1MB` streaming keyset encrypts each payload. The construction authenticates segment order and stream completion; the application does not implement its own streaming-GCM protocol.
- Derive 32 bytes of wrapping-key material from a separate parent-entered password using PBKDF2-HMAC-SHA256, a fresh 32-byte random salt and 600,000 iterations. The derived Tink AES256-GCM key encrypts the random streaming keyset. The Keystore and parent PIN are not used as archive keys. Benchmark the cost on the target tablet; changes to the construction require a new format version.
- Bound the accepted PBKDF2 iteration count to 600,000–2,000,000 before doing expensive work. Version 1 rejects any unknown algorithm identifier.
- Never use the 6–12 digit parent PIN as the export password. Require a distinct password of at least 16 characters, show guidance for a long multiword password, confirm it at export, and impose a maximum encoded length of 1,024 UTF-8 bytes. Define UTF-8 encoding without silent normalization so another installation derives the same key.
- Generate fresh salt and streaming-encryption randomness on every export. Never resume encryption with old per-stream key/nonce state. An interrupted export starts a new archive.
- Authenticate the exact versioned outer header as associated data. It includes the format identifier, version, KDF parameters, salt, streaming construction identifier and a random archive identifier. Public header fields contain no titles, channel names or rules.
- Run key derivation and cryptographic streaming on a native worker. Avoid retaining password text in Dart beyond submission; clear controllers promptly. Wipe mutable native password/key buffers when possible and make no guarantee that all runtime copies can be erased.
- Every restored stream must authenticate its terminal segment and reach the expected end before any video is published. Never play partially authenticated plaintext. A provider or crypto error fails the operation closed.

The 64-byte public header is associated data for the encrypted binary Tink keyset. The complete public header, bounded keyset length and encrypted keyset are associated data for the streaming payload. The archive never contains an unencrypted keyset. Format interoperability and negative tests remain required; successful compilation alone does not establish them.

## Version-1 archive framing and bounds

The extension is `.mitsbackup`. The public framing uses big-endian integers:

| Field | Size/value |
| --- | --- |
| Magic | 8 ASCII bytes `MITSBKP1` |
| Format version | 2 bytes, value 1 |
| KDF and stream identifiers | 1 byte each, both value 1 |
| PBKDF2 iterations | 4 bytes, exported as 600,000 |
| Salt | 32 random bytes |
| Archive identifier | 16 random bytes |
| Encrypted keyset length | 4 bytes, bounded to 1–2,048 |
| Encrypted Tink binary keyset | Exactly the declared length |
| Streaming ciphertext | Authenticated payload described below |

The fixed header through the archive identifier is exactly 64 bytes. Parse and
validate all bounds before allocating from archive-controlled lengths. Independent
fixtures must verify this layout and the associated-data bytes.

The decrypted payload is an ordered, length-delimited sequence, not a ZIP or a filesystem tree:

1. Eight ASCII bytes `MITSARC1`, followed by a big-endian 4-byte length and a UTF-8 JSON manifest of at most 256 KiB.
2. Video payloads in manifest order, each preceded by its big-endian 4-byte index and 8-byte length. Lengths must match the authenticated manifest.
3. Eight ASCII bytes `MITSEND1`, the manifest SHA-256 (32 bytes), entry count (4 bytes) and total media bytes (8 bytes), followed by authenticated end of stream. Reject truncation, duplicate records, extra trailing plaintext and extra trailing ciphertext.

The parser rejects duplicate JSON keys, unknown mandatory fields, invalid UTF-8, invalid numeric ranges and unknown format versions. It does not deserialize executable objects. No field is treated as a destination filename, URI to fetch, or filesystem path.

The root manifest has exactly `version`, `videos` and `rules`. Fields per video are `id`, `source_url`, `title`, `author`, `channel_id`, `bytes` and `sha256`: canonical 11-character YouTube ID, exact `https://www.youtube.com/watch?v=ID`, nonempty title/author, canonical `UC…` channel ID, positive plaintext size and lowercase SHA-256. Approval/save timestamps are not exported; fresh destination timestamps are assigned on restore. Titles/authors are bounded to 4 KiB UTF-8 each. Export strips unsupported optional metadata.

Maximum eight videos; no duplicates. A restored MP4 may be at most the existing 1 GiB source budget plus the 16 MiB mux allowance, to admit the app's own muxed output. The total plaintext video budget is eight times that bound. Enforce both per-entry and total byte counts during streaming, irrespective of advertised lengths. The manifest/rules budgets are additional small, fixed bounds. No compression is used, so there is no decompression expansion.

Validate codec/container metadata locally before approval: MP4, AVC/H.264 video no taller than 720 pixels, AAC audio, no unsupported extra tracks, valid positive duration no longer than 24 hours, and bounded MediaExtractor reads. Read no URI or external media referenced from file metadata. Check SHA-256 against the manifest and actual byte count after authenticated decryption. Keep full file integrity checks at subsequent playback opens.

Rules are null or exactly the current four schema keys: `blockedChannels`, `blockedKeywords`, `blockShorts` and `blockLive`. Each blocked list is bounded to 256 entries of at most 1,024 UTF-8 bytes each. Any future rule schema requires an explicit migration; unknown rule types do not silently become permissive defaults.

## Android document selection and parent authority

Use Android's Storage Access Framework: `ACTION_CREATE_DOCUMENT` for export and `ACTION_OPEN_DOCUMENT` for an archive restore. Request only the individual URI grant needed for that operation. Avoid broad storage permissions, media collection scanning and persistent URI grants by default. Export can use MIME `application/octet-stream` with the archive extension; validate actual archive framing on restore rather than trusting a filename or provider MIME type.

Opening the document picker backgrounds the activity and must revoke the existing parent session exactly as today. The picker result can retain an ephemeral selected URI and show a locked continuation screen; it must not restore authority, derive a key, decrypt, export or commit on its own. The parent unlocks again after returning, then deliberately continues. Recheck session token/epoch after every asynchronous picker or authentication boundary.

Password entry, restore previews and final approval are parent-only surfaces protected by the existing secure-window policy. Backgrounding, cancellation or session expiry revokes those surfaces and cancels the export/restore worker, closes URI descriptors, drops keys and cleans uncommitted plaintext staging. Do not add a backup-specific exemption to lifecycle locking. If large backups make the five-minute policy impractical, resolve that explicitly with a separate, narrowly scoped job design and tests.

Cancellation must reach native work cooperatively, including between segments and after key derivation. A late callback cannot publish files or revive an approval dialog. Provider hangs need bounded reads/writes and cancellation paths tested against a fake provider.

## Export flow

1. Authenticate the parent, select entries, and show the selected count/bytes and rules inclusion. Export only entries which have valid approval/channel/hash metadata and intact local files. Do not silently export legacy, damaged or currently blocked entries.
2. Obtain the output URI, then require a fresh parent unlock after the picker round-trip. Collect and confirm the separate export password.
3. Acquire the app's library-operation lock. Prevent simultaneous deletion, download publication and restore from changing the selected snapshot. Do not hold an SQLite transaction open while streaming gigabytes.
4. Recheck current rules, containment, sizes and hashes. Stream the authenticated manifest and videos into the new provider document with bounded memory. Do not make a second plaintext copy for export. If a source file changes while read, abort and retain the original library.
5. Write the authenticated completion/end, flush and close successfully, and only then report export success. A provider may not support atomic renames or free-space reporting; handle write failures without claiming that the archive is complete.
6. On failure, remove only the newly created output document if its provider permits it. Otherwise report that an incomplete archive may remain and can be deleted. Never delete a pre-existing user document. Readers always reject incomplete archives.

A destination provider may sync the encrypted file to a cloud account. Android's
document picker shows the chosen destination. The app uses a generic selected
archive label and does not query provider metadata on the UI thread, avoiding a
provider-controlled delay during return from the picker. It does not claim that
an external provider is local-only. Archive size and public header/KDF fields
remain observable even though media and metadata are encrypted.

## Restore flow and publication

1. Authenticate, select one archive, return locked from the picker, and authenticate again. Enter the archive password. Do not alter the destination PIN or existing content.
2. Validate the public header/KDF bounds and authenticate/decrypt the bounded manifest. Check space for all archive videos plus the existing 128 MiB reserve before staging; subset selection follows full inspection. Recheck the reserve during staging. Calculate available destination slots before publication.
3. Decrypt into an app-private `.restore-<random>` staging directory using application-generated names, never archive paths. Authenticate every segment and the entire ordered stream even when skipping unselected entries. Full archive authentication is required before publication. Ensure cleanup handles cancellation, process death, failed tags, incorrect passwords and truncated providers.
4. Validate byte counts, hashes and codecs. Show each title/channel and let the parent privately preview the staged local media. Label it as restored content requiring review; archive approval timestamps confer no authority. Apply current destination rules to the proposed entries.
5. The parent explicitly selects/approves eligible entries. Duplicate IDs never silently replace existing files: keep the current item, or require deliberate prior parent deletion. Restore only into free slots; no implicit eviction. Reject a ninth entry in the same database transaction that inserts the selected rows.
6. Under the shared library-operation lock, flush a bounded temporary journal and atomically rename it to its final journal name before moving any media. The journal contains the operation identifier and generated final basenames only. Verify every staged file's containment, size and full SHA-256 before moving it into a unique final private path. Insert all selected records and the restore job's `restore_commits` marker in one SQLite transaction, with fresh approval times. Database schema version 3 adds this marker table.
7. On restart, reconcile the journal before exposing the library or allowing another library mutation. If the database commit is present, preserve the committed files and clean staging; if absent, delete only the files created by that job. Never delete or restore over pre-existing records/files. Test each process-death point around journal creation, file moves, SQLite commit and journal cleanup.

The shared mutation lease coordinates download, backup/review, restore and parent deletion; ordinary child reads remain available. Startup recovery finishes before native inspection can start. It also removes recognized incomplete temporary journals and abandoned native `.restore-UUID` directories without following symlinks. A normal Save cannot acquire the lease while restore owns unpublished final files. Filenames alone are insufficient to coordinate concurrent writers.

The implementation merges selected new entries without replacing the existing library. A future replacement mode is a separate destructive operation with separate recovery requirements.

## Restoring rules

The archive includes a rules snapshot, but destination rules remain effective during video restore. After successful video restoration, the parent may review a separate old-versus-archive rules comparison and explicitly choose to apply it. Current rules are retained by default.

Apply rules through the authenticated settings repository, verify the write
result, and report its success separately from video restoration. This avoids
claiming an atomic transaction across SQLite and SharedPreferences. The repository
serializes settings writes and keeps readers from observing the plugin's
optimistically updated cache. A failed or interrupted write attempts to persist
the last confirmed value again. If that compensation succeeds, previous rules
remain active; if it cannot be confirmed, rule reads in the running app fail
closed until a parent successfully saves settings again. Merely reloading the
plugin cache does not establish disk persistence. Applying archived rules must
not alter the PIN/session configuration. A more permissive rules snapshot
requires an explicit parent choice; it is never a hidden restore side effect.

## Verification required before release

- Independent format fixtures and streaming-AEAD test vectors; same password/archive interoperability across two Android versions/devices.
- Wrong password; every header/manifest/ciphertext field tampered; reordered, duplicated, missing and trailing segments; forged lengths; unsupported versions/algorithms; extreme KDF costs.
- No plaintext media/title/rules leakage in the exported archive; no PIN/Keystore/settings-secret inclusion; no secrets in errors, logs, screenshots or release evidence.
- Picker cancellation, provider denial, read/write hang, returned URI after backgrounding, late auth response, five-minute expiry, force-stop and restart at every publication checkpoint.
- Low space before transfer and during restore, missing/corrupted source files, unsafe file/URI/path fields, symlink staging attacks, invalid/oversized media and codec failures.
- Eight-slot enforcement, duplicate preservation, current-rule enforcement, deliberate fresh approval, failed settings restore and interruption without existing-data loss.
- Exact signed release tests of SAF grants, native cryptography, codec inspection and playback after restore with Android networking disabled.

Do not claim full release acceptance until these checks have measured results. Record partial coverage and unresolved provider/device cases explicitly. Production signing and existing-installation update compatibility remain separate release gates.

# Verified SMB download checkpoints

Gumbo keeps an interrupted SMB song in a hidden checkpoint, separate from completed audio. When the app resumes or the user retries after relaunch, it opens the song with the same authenticated SMB policy and verifies every saved byte before appending the remaining bytes. Completed songs are retained as before. Reopening a file never skips a prefix merely because its path, size or modification time matches.

## Representation and access rules

The new `gumbo_smb2_open_read_snapshot` requests an ordinary read handle with only `FILE_SHARE_READ`: cooperating SMB clients can read the song, but cannot open it for writing, deletion or rename while the handle is held. An existing incompatible writer makes the protected open fail. The open does not follow a reported final reparse point or automatically retry a symlink target. This follows the [SMB2 CREATE ShareAccess contract](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/e8fb45c1-a03d-44ca-b7ae-47385cfd7997).

The same handle supplies the initial stat, prefix comparisons, remaining reads and final stat. Type, file ID, size, birth/change/modification timestamps must agree before publication. Observed changes invalidate the result. These fields are **not** a persisted strong validator. The handle protection applies to cooperating SMB clients, not arbitrary server-local POSIX writers or other protocols that bypass SMB share modes. Those writers can still race; the stat checks reject observed mutations but cannot prove a snapshot when a server permits undetectable out-of-protocol changes.

Each protected file transfer owns a separate authenticated context and serial queue. It cannot hold up playback range requests, seeks, covers or scans on the ordinary shared session. It uses the same account/security settings, closes when the operation ends, and receives the same task cancellation on access revocation. A fixture suspends a download while proving an ordinary playback read completes independently.

If a local prefix differs, Gumbo retains only the already verified prefix and rewrites the suffix from the current protected handle. A lost connection retires that handle; the automatic retry opens a new one and starts verification again at byte zero. Short nonempty reads are handled; premature EOF, oversized replies, cancellation and stat changes cannot become a completed download. The library remains read-only: the protected open does not change music files.

## Persisted scope and lifecycle

Each descriptor binds source identity, exact remote path, profile identity, access epoch and deletion epoch. It contains no password or authenticated URL. Checkpoints use a hidden subdirectory so normal cache discovery cannot mistake even a full-length interrupted payload for completed audio. Payload chunks are synchronized before continuing. Relaunch still presents interrupted foreground work as a retry; it does not silently fetch fresh credentials.

Signing out, selecting another server or deactivating a profile invalidates the access epoch and removes checkpoints. Confirmed server deletion removes the exact track checkpoint. Cancel/Remove clear interrupted files; unused orphan checkpoints are swept after restoration. A retry cannot begin using a checkpoint path until the old foreground transfer has unwound, and task/attempt checks reject late completion. On success, the verified payload is moved to that attempt's incoming file and passes the existing completion checks before becoming a downloadable record.

## Tradeoff and verification

This is persisted **disk-prefix reuse**, not bandwidth-saving network resume: the retained prefix is reread over SMB to prove its bytes. It avoids rewriting verified disk bytes but does not make a large interrupted song consume less network traffic on retry. A bandwidth-saving strategy would require an independently proven stable representation contract across reconnects.

`SMBResumeTests` and `ForegroundCheckpointTests` cover partial/chunk-boundary prefixes, same-size changed content, interruptions, relaunch, background pause, cancellation and delayed native-like completion after revocation, deletion and local removal. `SMBResumeIntegrationTests` uses only UUID-named generated files in the disposable loopback Samba container's `resume-tests` share; its writer control proves that a denied write is caused by the protected handle rather than an account permission failure. The fixture has no writable host/NAS mount. See [fixture instructions](../Tools/SMBReadFixture/README.md).

These tests establish the implemented Samba/share-mode behavior. They do not certify other NAS firmware, physical-device background behavior, or a malicious/nonconforming server.

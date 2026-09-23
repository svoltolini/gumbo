# Shared-library maintenance and playlist artwork

Tracked by #134, #135 and #136. These changes apply to the shared SwiftUI app on iPhone, iPad, Mac and Apple TV. The Watch remains a playback companion.

## Behavior

Made for You uses four distinct generated covers: rose, plum, teal and amber, with quiet record-groove details. Existing Reduce Motion support remains in place. Accessibility text sizes use one column, smaller covers and wrapping titles/descriptions instead of clipping names into two narrow columns.

Advanced Settings contains two owner-controlled tools. **Find Missing Genres** searches Apple's music catalogue only after the person starts it. Album and full artist credit must match after conservative case, accent and punctuation normalization; edition suffixes and joint credits are not discarded. Conflicting genres produce no suggestion. The person can enter a genre manually, select albums, and confirm writing the original NAS files. The writer reads the actual tags again, preserves existing genres, verifies rewritten metadata, and reports partial failures. No display-only genre alias is created on failure.

**Problem Files** checks songs with no duration or repeatedly unreadable metadata. A filename, artist, playback error, unsupported codec, failed request, or missing permission is never grounds for deletion. Only an old empty file or a structurally incomplete MP4 container can be selected. Results show the exact path and reason; selection starts empty. Deletion requires confirmation, then repeats inspection and checks the reviewed size and modification time. Successfully deleted tracks disappear from the current catalogue; other NAS users see removal on their next update. Managed downloads on this device are removed after confirmed deletion; other devices and Watch reconcile after a successful library refresh/sync. Independent copies and backups remain.

## Important scenarios and protections

| Scenario | Behavior / coverage |
| --- | --- |
| Different servers, accounts, roots or profiles | Reviews are scoped to source, root and unlocked session. Changed contexts cancel work and clear results. Core writes check source identity. |
| Family member or locked owner | Shared maintenance is rejected. This is app authorization; NAS permissions remain authoritative. |
| Read-only NAS account / denied file operation | Show per-file failures. Tag batches stop making uploads after the first permission refusal. Never fall back to a local genre alias in this workflow. |
| No network, expired sign-in, missing file, short response | Report the check as unavailable. Do not label the file corrupt or enable deletion. |
| Active download / conversion | Files modified within an hour, without a modification time, or changing during inspection are kept. Recheck once work finishes. |
| Valid music with a hash filename | Parse its actual audio container. A readable index is kept even when the filename resembles a failed conversion. |
| Hidden `._` companions left by macOS copies | Never songs or covers: scans skip them, Problem Files never lists them, and tag writes and deletion refuse them. A library indexed by an older build drops them on its next complete update without reporting them as deleted from the NAS, and fetches the real picture for any cover it had saved from one. Albums they had filed under Various Artists return to their artist with a new identity; songs downloaded for the old one still play offline, and downloading the album again reuses them instead of fetching them. |
| Unsupported / unusual format | Keep the file for a separate check. Raw AAC, non-MP4 formats and unrecognized MP4 layouts are not condemned because parsing failed. |
| Huge / malformed MP4 headers | Bound reads, arithmetic and atom count. Parsing runs away from the UI thread. |
| Unknown album, regional catalogue gap, remix/deluxe edition, several artist credits | Exact full-credit matching; no guess when the result is absent or ambiguous. Manual genre entry remains available. |
| Lookup throttling / service failure | Space requests across windows, cache successful suggestions, stop a batch on provider failure, and allow cancellation. |
| Cached missing genre but actual file already has one | Keep the on-disk genre and update the catalogue with it. |
| Two clients rewriting the same file | Unique upload/backup names; compare file versions before moving the original and again on the moved backup. Restore a conflicting file rather than overwrite it. A genre review also checks the cached file version before preparing a change. |
| Interrupted upload / cancellation / profile lock | Remove the staged copy where possible; check cancellation and authorization before swapping. Completed changes remain reported. |
| Failed swap / failed rollback | Attempt restoration, including when the server may have moved a file but its response was lost. If restoration fails, keep the backup and tell the user where to check; never silently delete the last original. |
| Earlier interrupted write left a backup | Preserve that unrelated backup. Never clear another transaction's files. |
| Device runs out of disk or file exceeds the tag writer's bound | Surface the error; original files are not replaced with incomplete transfers. Scratch copies are cleaned up. |
| Large text / small screens / Reduced Motion | Native scrolling forms, wrapping help and failure text, accessible controls; existing animation reduction on artwork. |

## Limits and acceptance boundaries

- This is a conservative structural check, not a full audio-decoding scan of every song. Files with existing duration that later become damaged are outside the automatic candidate set; users can refresh song information before checking. Some damage will require the original conversion software or a separate audio checker.
- File Station does not offer an atomic compare-and-delete transaction here. Size/mtime and repeated structural checks reduce races but cannot prove that another writer did not modify a file in the last instant, or preserve its size and timestamp. Stop other conversions or edits before confirming deletion. Tag replacement also cannot provide a distributed lock against arbitrary external tools.
- A NAS may retain deleted files in its own recycle bin or snapshots. Gumbo offers no undo for a delete and does not erase NAS backups or independent copies. Managed Gumbo downloads are reconciled as described above.
- The new flows do not silently repair or delete anyone's NAS files. The supplied damaged example and a valid hashed-name example were inspected read-only; production tag writes and deletion require the user's review in the app.
- Genre suggestions are broad catalogue classifications, not authoritative musicology. Existing labels are kept and suggestions always require selection and confirmation.
- Signing/build success and offline UI tests do not prove live DSM permissions, interrupted transfers, CloudKit, multi-device propagation or TestFlight distribution. Those remain explicit acceptance cases in #123; distribution and published store/privacy metadata remain in #118 and #119.

## API references

The lookup uses Apple's [iTunes Search API](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/Searching.html), including its documented approximate request allowance. File mutations use the existing File Station adapter and the synchronous deletion method documented in Synology's [File Station API guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf), pages 90–94. Privacy disclosures now describe the optional text lookup and shared-file changes.

## Validation

- 455 Release core tests in 28 suites passed, including new genre matching, file inspection, authorization, cancellation, replacement conflict, lost-response and rollback tests.
- Seven iPhone simulator UI journeys passed. The maintenance and artwork checks also passed at the largest accessibility text size after fixing playlist clipping and making the tests scroll native Forms.
- The two maintenance/artwork journeys passed on iPad mini. The launch helper now waits for the destination navigation bar because iPad's native top tab strip is not exposed as an iPhone-style tab bar.
- Signed iPhone + embedded Watch/widgets Release build, unsigned Mac Release build, and Apple TV simulator Release build passed. All shipping targets use version 1.0 (202609201803).
- The production inspector passed a read-only check against the supplied damaged NAS file and the valid hashed-name file. No original NAS file was written or deleted. The temporary private integration fixture was removed from the repository.
- Screenshots inspected for the new covers, native maintenance screens, and large-text layout. No real server metadata or artwork is included in the committed fixtures.

## Provider update, 21 September

[Provider validation evidence](PROVIDER-COMPATIBILITY.md) records protected SMB inspection/deletion and optional helper-backed maintenance. Read-only inspections no longer produce a usable deletion witness. SMB checks and reads the same protected handle; the optional helper returns inspection ranges from a full-file fingerprint pass. Lost deletion acknowledgements stop the batch, including after Stop, and confirmed local cache-save failures are reported separately from NAS deletion results. Generic WebDAV mutation headers still do not enable raw writes.

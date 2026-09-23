# Delete an album from the NAS

Tracked in [#183](https://github.com/svoltolini/gumbo/issues/183).

On iPhone, iPad or Mac, the library owner can open an album's menu and choose **Delete Album…**. Gumbo checks the exact song files and presents their count and paths before **Delete from NAS** becomes available. NAS write permissions still apply. Album folders, artwork and unrelated files are kept. The confirmation clearly states that the original songs are removed for everyone and Gumbo cannot undo the operation.

## Authority and failure handling

- The review is bound to the open owner profile, current NAS login, source, music folder and catalogue revision. A new review supersedes an older one, and each review can be consumed once.
- Only unique, known music-file paths strictly below the selected root are eligible. Paths overlapping another album, directories, traversal components and unverifiable remote files are rejected.
- Hidden files are never songs. The `._` companions macOS leaves beside copied files (for example `._01 - Song.flac` on an SMB share or exFAT drive) are not reviewed, counted or deleted with the album; like artwork, they stay on the NAS. A library indexed before hidden files were ignored may still list them until its next complete update; until then its review asks for that update instead of proceeding.
- File size and modification time are checked during preparation and again before each delete. The server receives an exact path with recursive deletion disabled. The remote stat and delete are separate requests; File Station does not offer an atomic conditional delete here.
- Profile, server or library changes stop subsequent files. Stop lets the current request finish so an acknowledged deletion is accounted for. Partial results distinguish confirmed deletions from failed or unconfirmed requests; a lost acknowledgement can require a refresh.
- Only acknowledged files are removed from the local catalogue and active profile references. A local persistence failure is reported separately from the completed NAS operation.

## Other devices and downloaded copies

Confirmed source-and-track IDs remove this device's managed downloads for every profile, stop affected playback and retire outstanding downloads. Persistent deletion markers prevent late background completions from putting deleted files back.

Other devices discover removed songs after a complete successful NAS listing. Missing roots, unreadable subfolders, canceled scans and incomplete pagination cannot authorize download cleanup. Listing pages must make progress and agree about totals when supplied. A missing total is handled by continuing through full pages.

The paired Watch receives source-scoped deletion information through iPhone. Its manifest removes only matching managed audio, retires old transfer generations and stops affected playback. Ordinary playlist removal does not imply that its NAS files were deleted. Verified re-imports clear the applicable phone deletion markers before later Watch syncs.

Offline devices cannot learn about deletion until they reconnect and refresh or sync. This feature cannot remove independent copies, NAS backups or copies in other apps.

## Verification and device acceptance

Release validation for build 202609211143: all 561 core tests across 36 suites passed. Signed archives and exports passed for iOS (including Watch and widgets), universal macOS and tvOS; distribution signing, production CloudKit, shared personal Keychain access and CarPlay entitlement/scene checks passed.

Tests use in-memory drives, injected network responses and temporary download directories. They cover owner permissions, changed files and sessions, unsafe paths, concurrent operations, partial results, cancellation, persistence failures, complete versus partial listings, source-scoped download removal and late callbacks. UI fixtures render the review and results in light and dark mode. No real NAS files were deleted during implementation or testing.

The remaining physical-device check uses a disposable test album on a controlled NAS account: inspect the review, delete one copy, verify another device after refresh, verify its paired Watch after sync, then repeat with offline devices, denied write permissions and an interrupted connection. Do not use irreplaceable music for this acceptance check. The broader device acceptance is tracked in [#123](https://github.com/svoltolini/gumbo/issues/123).

## Additional provider routes

[Provider validation evidence](PROVIDER-COMPATIBILITY.md) extends this flow to protected-handle native SMB deletion and an optional NAS helper for read-only transports such as WebDAV. Helper deletion is explicitly disabled by default on both server and client. The app cross-checks the mapped file contents before presenting the review; confirmation uses a durable helper job with the expected fingerprint. Unconfirmed results retain the original job reference and stop subsequent files. Folder mapping remains an explicit owner responsibility. Device/NAS certification stays in #123/#198.

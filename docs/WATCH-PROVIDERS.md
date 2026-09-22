# Apple Watch providers (#195)

Gumbo keeps the existing DSM Watch connection. HTTPS WebDAV downloads directly on Watch. SMB music is prepared by the iPhone and sent as an audio file using WatchConnectivity; the Watch never receives the SMB username/password and never links libsmb2.

## Versioned handoff

`WatchCredentials` with no provider/version remains legacy DSM. Generic connections carry a validated `ProviderConfiguration`, protocol version 2, and the separately named `providerConnectionV2` payload. They never populate the legacy `baseURL/account/password` message keys that an older Watch interprets as DSM. An unsupported version or provider fails closed. A WebDAV credential must match the exact provider/root/account source ID; an SMB descriptor is only usable when both secret and account are empty. Secrets are stored only in provider-scoped Watch Keychain items, with non-secret descriptors in preferences.

The existing ordered `WatchAuthorization` still gates catalogues, credentials and new audio messages. A switch/lock revokes the previous grant and clears Watch data. Queued revocation is applied when connectivity delivers it; this does not promise instant revocation on a disconnected Watch.

The Watch clears everything whenever the revision moves, so the iPhone ties it to the open library (profile ID, source and music folder), not to the app process or the profile session, which is new on every opening (#219). The grant is saved with that library and its catalogue snapshot count. A relaunch, including a background one triggered by the Watch, keeps the revision: until a profile opens, the iPhone neither revokes nor sends a newer revision, and answers a Watch sync with the revision it last granted. Reopening the same library continues the grant and its snapshot order, so the Watch keeps its catalogue and downloads. The revision still moves, clearing the Watch, on a lock or profile switch, on a sign-out or other departure from a ready library open in this process, and when a different profile, source or folder opens, also after a relaunch. Updating from a version that saved no library clears the Watch once, when a library next opens.

## WebDAV

The Watch constructs paths using `WebDAVDrive`, then removes its preemptive Authorization header before scheduling the background download. The task challenge supplies credentials only for a matching active manifest/source, exact original/current HTTPS URL and endpoint root. Redirects are refused; a final response at a different URL is discarded. Background URLSession can finish after relaunch, using the saved source-specific credential. Default certificate validation remains enabled.

## SMB relay

Keep Gumbo open on a reachable iPhone while songs are prepared. Preparing a full file from SMB is a foreground, cancellable operation. Once prepared, the operating system can transfer it in the background. The Watch screen explains this distinction; it does not claim direct SMB streaming or background server downloads.

Each request carries the playlist identity and `WatchDownloadJob`, including source/profile cache identity, track ID, expected size, safe filename and attempt generation. The phone resolves the path from its current catalogue, verifies the authorization and deletion ledger before/after preparation, and transfers a dedicated temporary copy. Its provider callback additionally checks profile session, connection token, root, catalogue revision and exact track metadata. Only one file is prepared at a time. Cancellation, backgrounding and source/profile changes interrupt outstanding preparation. Prepared file transfers have their own ownership and cleanup.

The Watch stages incoming files away from the catalogue. It accepts them only for the current authorization, playlist membership, source/profile, active generation and expected size. A cancelled/retried/deleted file cannot revive an old manifest. Server deletion is still reflected when a device receives the updated catalogue, not by an instant remote wipe.

File revisions also detect same-size NAS edits in completed copies and reject old direct/relay completions. Optional fields preserve legacy decoding; existing files adopt a baseline without certifying their historical bytes. See [download freshness](DOWNLOAD-FRESHNESS.md) for the comparison and migration limits.

## Validation

`WatchProviderTests` covers legacy compatibility, unsupported payloads, exact WebDAV identity/root/redirect boundaries, secret-free SMB descriptors, source/profile ownership, malformed filenames, removed tracks, changed file sizes, cancellation and retries. `WatchGrantTests` covers the grant across relaunches: kept for the same library and while no profile is open, renewed for another profile, source or folder, revoked on lock or on closing a library opened in the process, snapshot ordering and the legacy migration. The signed iOS + Watch Release build passed on 2026-09-21; iOS links and embeds a signed GumboSMB framework, Watch does neither. Full phone-to-physical-Watch delivery, reachability loss, background preparation cancellation and post-relaunch completion remain device acceptance checks; unit/build success is not that evidence.

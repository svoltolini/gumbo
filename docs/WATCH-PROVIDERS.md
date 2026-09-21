# Apple Watch providers (#195)

Gumbo keeps the existing DSM Watch connection. HTTPS WebDAV downloads directly on Watch. SMB music is prepared by the iPhone and sent as an audio file using WatchConnectivity; the Watch never receives the SMB username/password and never links libsmb2.

## Versioned handoff

`WatchCredentials` with no provider/version remains legacy DSM. Generic connections carry a validated `ProviderConfiguration`, protocol version 2, and the separately named `providerConnectionV2` payload. They never populate the legacy `baseURL/account/password` message keys that an older Watch interprets as DSM. An unsupported version or provider fails closed. A WebDAV credential must match the exact provider/root/account source ID; an SMB descriptor is only usable when both secret and account are empty. Secrets are stored only in provider-scoped Watch Keychain items, with non-secret descriptors in preferences.

The existing ordered `WatchAuthorization` still gates catalogues, credentials and new audio messages. A switch/lock revokes the previous grant and clears Watch data. Queued revocation is applied when connectivity delivers it; this does not promise instant revocation on a disconnected Watch.

## WebDAV

The Watch constructs paths using `WebDAVDrive`, then removes its preemptive Authorization header before scheduling the background download. The task challenge supplies credentials only for a matching active manifest/source, exact original/current HTTPS URL and endpoint root. Redirects are refused; a final response at a different URL is discarded. Background URLSession can finish after relaunch, using the saved source-specific credential. Default certificate validation remains enabled.

## SMB relay

Keep Gumbo open on a reachable iPhone while songs are prepared. Preparing a full file from SMB is a foreground, cancellable operation. Once prepared, the operating system can transfer it in the background. The Watch screen explains this distinction; it does not claim direct SMB streaming or background server downloads.

Each request carries the playlist identity and `WatchDownloadJob`, including source/profile cache identity, track ID, expected size, safe filename and attempt generation. The phone resolves the path from its current catalogue, verifies the authorization and deletion ledger before/after preparation, and transfers a dedicated temporary copy. Its provider callback additionally checks profile session, connection token, root, catalogue revision and exact track metadata. Only one file is prepared at a time. Cancellation, backgrounding and source/profile changes interrupt outstanding preparation. Prepared file transfers have their own ownership and cleanup.

The Watch stages incoming files away from the catalogue. It accepts them only for the current authorization, playlist membership, source/profile, active generation and expected size. A cancelled/retried/deleted file cannot revive an old manifest. Server deletion is still reflected when a device receives the updated catalogue, not by an instant remote wipe.

## Validation

`WatchProviderTests` covers legacy compatibility, unsupported payloads, exact WebDAV identity/root/redirect boundaries, secret-free SMB descriptors, source/profile ownership, malformed filenames, removed tracks, changed file sizes, cancellation and retries. The signed iOS + Watch Release build passed on 2026-09-21; iOS links and embeds a signed GumboSMB framework, Watch does neither. Full phone-to-physical-Watch delivery, reachability loss, background preparation cancellation and post-relaunch completion remain device acceptance checks; unit/build success is not that evidence.

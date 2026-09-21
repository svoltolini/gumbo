# NAS providers beyond Synology

Status: implementation plan, 21 September 2026. Parent: [#155](https://github.com/svoltolini/gumbo/issues/155).

The released app supports Synology DSM/File Station. Nothing in this document changes that claim. Additional providers become supported only after their documented configurations pass the acceptance matrix below.

## Priority and scope

Start with **QNAP**, using a reusable **HTTPS WebDAV** provider. Add **SMB 2/3** as the second transport, with its feasibility work running early in parallel. Validate additional NAS families against these adapters rather than building a separate proprietary API for every brand.

This is an evidence-informed order, not a verified global market-share ranking. [QNAP reports over seven million NAS users](https://www.qnap.com/en-us/developer), which supports its priority but is not a comparable annual sales or active-device metric. Public rankings depend heavily on geography and sales channels: [BCN's 2026 NAS awards](https://www.bcnaward.jp/award/gallery/detail/contents_type%3D200) place Buffalo, I-O Data and Synology first through third in their Japanese retail data. Neither source establishes a global second-place percentage. Revisit priority using beta users' requested NAS models and actual successful connections; do not add telemetry solely for this decision.

| Delivery wave | Target configurations | Qualification required |
| --- | --- | --- |
| Existing | Synology DSM/File Station | Preserve current behaviour, identity and saved data throughout |
| 1 | QNAP QTS / QuTS hero over HTTPS WebDAV | Record and test each actual firmware family; QTS documentation alone does not certify QuTS hero |
| 1 expansion | ASUSTOR HTTPS WebDAV; other standards-compliant WebDAV servers | Named model/firmware/server versions, permissions and range support |
| 2 | TrueNAS, Unraid and QNAP/Synology SMB shares; Samba/Windows interoperability | SMB 2/3 dependency, signing/encryption, distribution and device gates |
| Subsequent certification | TerraMaster, UGREEN, OpenMediaVault, Buffalo and I-O Data configurations | Confirm protocol availability and lifecycle first; ordering follows demand and test access |

TrueNAS's current WebDAV option is an additional application, not the removed legacy built-in service. Do not advertise built-in WebDAV on Unraid. A standards-compatible server can be tried using “Other NAS”; that is not a guarantee for every brand, model or firmware.

In scope: browsing and indexing, local artwork and tags, seeking and playback, offline downloads where supported, reconnection, personal credential sync, family access, favourites/playlists continuity, Watch delivery, and safely gated maintenance/deletion. Keep music on the user's server or their devices; no Gumbo relay service or account is introduced.

Out of scope for this epic: Plex/Jellyfin/Subsonic media-server APIs, NFS, FTP/SFTP, cloud-drive services, SMB1, automatic merging of multiple libraries, server-side transcoding, and silently migrating a library between protocols. These need separate product decisions. Existing file-format support remains the baseline.

## Current coupling to remove

`RemoteDrive` already supplies folder enumeration, byte reads, downloads and a stream URL. `WritableRemoteDrive` adds mutations. The implementations above those interfaces still assume DSM in several places:

- `AppModel` and connection services probe DSM, construct `DSMSession` / `SynologyDrive`, and interpret DSM errors.
- Saved `ServerConnection`, `FamilyInfo`, `NASSource` identity and credentials assume an HTTP origin plus account. Meaningful WebDAV base paths and SMB shares/domains are not represented.
- Discovery can turn an SMB advertisement into a DSM connection proposal. An SMB advertisement must never establish provider identity or authorize sending DSM credentials.
- `streamURL(for:)` cannot express authentication challenges, asynchronous resolution or an SMB byte reader. Metadata probing also uses media assets; adapting only the player leaves indexing broken.
- Background downloads assume HTTP URLSession transfers. Watch download authentication is directly tied to DSM.
- Broad write conformance and Synology error codes do not establish safe write permissions on another provider.

## Architecture decisions

### Connection, identity and migration

Introduce a versioned `ProviderConfiguration` value and provider/session registry. It carries a stable provider kind, display name, endpoint, selected share/base path, authentication mode and a secure credential reference. Passwords and session tokens remain outside catalogue JSON, URLs, logs and CloudKit public fields.

Use separate models for connection discovery hints, authenticated sessions and the selected music root. Authentication is performed only for the explicitly selected endpoint. Default to HTTPS for WebDAV, trusted certificates and standard platform trust handling. No certificate bypass, automatic HTTPS-to-HTTP downgrade or cross-origin credential forwarding. An explicitly configured private HTTP connection needs the existing informed warning; remote access documentation should recommend a trusted HTTPS endpoint or private VPN, never exposing SMB to the public internet.

Preserve existing Synology source hashes, track IDs, cache paths, Keychain entries, favourites, playlist references and download ownership exactly. A missing provider in a recognised legacy schema means Synology. An unknown provider or future schema is unsupported, not Synology by default.

New identities include provider, normalized endpoint, meaningful WebDAV base path or SMB share, authentication realm/domain where relevant, and account. The music-root policy must be explicit: expanding/changing a selected folder must not silently create aliases or merge unrelated sources. Use provider-defined path case rules, normalize encoding once, retain Unicode filenames and reject traversal outside the selected root. Host aliases and alternate protocols remain distinct unless a later, explicit migration verifies equivalence.

Family and Watch payloads get additive versioned envelopes. For non-Synology sources, do not populate legacy DSM-address fields that would make an older client attempt DSM authentication against the wrong server. Test old-reader fixtures: older binaries must reject or ignore incompatible payloads without network or destructive cleanup operations. Clients implementing the new version checks show an update-required state; an already shipped binary cannot gain that screen retroactively.

### Read contract and errors

Retain provider-neutral listing and bounded random-access reads, with stat/version information and explicit cancellation. Enumeration must return a complete page sequence or an error. A timeout, denied subtree, incomplete response or authentication failure must not appear as an empty folder: the current catalogue reconciliation can remove local download ownership when files appear absent.

Normalize errors into authentication/expired credentials, access denied, confirmed missing resource, unsupported operation, conflict/version changed, throttled/retryable, connectivity, certificate and cancellation. Preserve enough diagnostic context for Advanced Settings without displaying credentials or raw server bodies. Retry bounded, idempotent reads with backoff; never blindly replay a destructive mutation after an uncertain response. Bound authentication challenges separately and request corrected credentials after rejection rather than repeatedly trying a saved password and locking the NAS account.

Use capabilities at both provider and authenticated-account/root level. Distinguish listing, ranged reads, stat/version, playback strategy, background transfer, upload, rename, exact-file deletion, conditional replacement and account administration. UI visibility is only one guard; core operations enforce capabilities and ownership again. `OPTIONS Allow` and a writable protocol type are not proof that this account may safely perform every mutation.

### Playback, metadata and transfers

Replace the synchronous optional stream URL with an asynchronous media-resource descriptor: authenticated HTTP resource, random-access byte source, or verified local file. Share resolution between playback, artwork/metadata probing and downloads. Preserve playback intent revisions and cancellation when the user changes song, source or profile. Retain resource-loader delegates for the request lifetime and isolate their callbacks from UI state.

Use documented authentication challenges and `AVAssetResourceLoaderDelegate` where appropriate; do not depend on undocumented AVURLAsset header options. Check seeking against actual responses: `206` plus a valid `Content-Range` and byte count, validators, EOF and `416`; a `200` response that ignores Range cannot be treated as the requested fragment. Bounded whole-file local fallback may be offered when seeking is unavailable, with clear storage and progress feedback. Large files must not be buffered fully into memory.

Keep separate transfer engines:

- HTTP/WebDAV: authenticated URL requests and system background sessions where the platform supports them. Reassociate restored tasks with current source/owner and obtain credentials securely after relaunch.
- SMB: bounded file streaming with resumable checkpoints only when file identity/version still matches. Do not promise HTTP-equivalent background execution. Suspended work should say it will resume when Gumbo can continue, rather than show a stuck spinner.

Preserve existing attempt IDs, managed-download memberships, profile/source boundaries and deletion tombstones. Restore favourites/playlists and requested offline memberships across devices; actual audio remains device-local and is not automatically downloaded by syncing membership.

### WebDAV implementation

Implement `PROPFIND Depth: 0/1` with namespace-aware XML parsing, entity expansion disabled, response-size/depth limits and explicit per-resource/per-property `207` results. Resolve `href` safely against the configured endpoint; reject cross-origin references and paths outside the chosen scope. Handle trailing slashes, escaped characters and servers returning absolute or relative references without double decoding.

Support HTTPS authentication challenges for the modes validated in the provider matrix, including ordinary username/password setups. Do not claim enterprise SSO or every Digest variant without tests. Root listing, stat, `GET` byte ranges and streaming form the first read-only milestone; writes are a separate capability milestone. Validate actual server behaviour instead of relying solely on advertised methods/range headers.

### SMB implementation and dependency gate

Evaluate AMSMB2/libsmb2 and the pure Swift alternatives with a signed-device proof before locking in a dependency. Required baseline: SMB2/3 dialect negotiation, no SMB1 fallback, authenticated session isolation, secure signing policy, SMB3 encryption when requested/required, Unicode paths, cancellation, reconnect, bounded reads and correct error mapping. Explicitly model local/domain accounts; guest access must be a deliberate option, never an automatic fallback after failed authentication.

AMSMB2/libsmb2 is a plausible SMB2/3 candidate; its upstream licensing and dynamic packaging requirements must be reviewed for App Store distribution. A package's platform declarations do not prove production signing or Watch networking works. The currently documented SMB2.0/iOS/macOS scope of the MIT Swift SMBClient alternative is insufficient evidence for full SMB3 or five-platform support. Record a dependency decision, notices and packaging evidence before shipping.

The SMB work stays in scope even if a candidate fails. Select another acceptable implementation or report the concrete remaining blocker; do not close #155 merely because WebDAV works.

### Watch, CarPlay and platform behaviour

| Platform | WebDAV | SMB | Acceptance focus |
| --- | --- | --- | --- |
| iPhone / iPad | Browse, stream, seek, offline transfer | Browse, stream, seek; resumable transfer with honest suspension limits | Locked screen, interruptions, reconnect, iPad layout |
| Mac | Browse, stream, seek, offline transfer | Same, including sleep/wake reconnect | Native setup, permissions and playback state |
| Apple TV | Browse and stream | Browse and stream if dependency/platform validation passes | Focus navigation, large libraries, family credentials; no new offline-download promise |
| Apple Watch | Download selected music over authenticated HTTPS; play local files | Paired iPhone downloads and transfers selected files, or an explicitly configured HTTPS endpoint | Physical paired-device tests, revocation, storage, background delivery |
| CarPlay | Uses the iPhone catalogue and player | Uses the iPhone catalogue and player | No credential setup while driving; failures recover on phone |
| Widgets / Live Activities | Reflect existing library and download state | Same where transfers exist | Source isolation; Live Activities describe downloads |

Apple limits low-level networking on physical Watch and does not support BSD sockets there. A simulator success is not proof of independent Watch SMB access. Phone-to-Watch file transfer is asynchronous: show waiting-for-iPhone, transferring, available and failed states. Retain credential, catalogue and profile revisions; reject late transfers after logout, source changes or album deletion. An optional HTTPS endpoint requires explicit ownership/root mapping and must not silently alias unrelated libraries.

### Setup, family access and maintenance

Offer understandable choices such as Synology, QNAP and Other NAS. Brand selection suggests documented settings; the saved configuration is the actual protocol. Explain required NAS service setup before requesting credentials. Follow address → account → music folder → connection check → library scan, with cancellable work and a usable UI during scans. Keep protocol ports, certificate detail and diagnostics under relevant advanced help.

Personal iCloud Keychain sharing remains opt-in for supported devices and scoped to the exact provider configuration. Preserve the Apple TV limitation and paired-iPhone Watch delivery. Family Access remains a separate consented feature. Synology-only automatic account creation/rotation stays behind an account-administration capability; other providers can use a user-prepared restricted account, validated without requesting administrator credentials for normal listening.

Read-only libraries must support normal browsing and playback. Metadata/tag maintenance and host album deletion are available only when their safety prerequisites pass. For WebDAV, strong validators and conditional requests plus verified staging/rename semantics are needed; weak ETags or `Overwrite: F` alone are not sufficient concurrency protection. For SMB, verify the selected library exposes the necessary file identity and mutation guarantees before enabling writes.

Revalidate authority, root, file version and permissions before each confirmed operation. Album deletion acts on reviewed exact music files only; never delete a folder recursively or infer that an uncertain request succeeded. Keep artwork/unrelated files unless separately reviewed. Handle partial completion explicitly and propagate confirmed removals through existing catalogue/download/Watch cleanup. Tag replacement preserves the original until a verified replacement and rollback path are available. Provider tests use disposable fixtures; no automatic deletion of users' libraries.

Performance follow-up [#201](https://github.com/svoltolini/gumbo/issues/201) evaluates an optional server-side tag-edit capability so only metadata changes cross the network. Synology documents Audio Station's editing UI, but a supported integration API still needs verification; a restricted NAS helper is an alternative requiring separate setup. Do not mistake WebDAV properties or unguarded SMB byte writes for safe embedded-tag updates. The client rewrite remains the fallback, and installing a helper is not required for ordinary listening or provider compatibility.

## Delivery and tracking

Create bounded child issues for the following work. The parent remains open until both transports and the documented cross-platform experience are delivered or its scope is explicitly revised.

1. [#190 — Foundation](https://github.com/svoltolini/gumbo/issues/190): versioned configuration, provider registry, normalized capabilities/errors and identity migration; refactor Synology through the same entry points without changed identities.
2. [#191 — SMB feasibility](https://github.com/svoltolini/gumbo/issues/191): dependency/license/packaging decision and signed iPhone/Mac/TV proofs; document Watch's transfer route. Run alongside the foundation.
3. [#192 — WebDAV reads](https://github.com/svoltolini/gumbo/issues/192): secure enumeration/stat/authentication/range adapter with a deterministic fixture server and contract tests.
4. [#193 — Media and downloads](https://github.com/svoltolini/gumbo/issues/193): asynchronous media descriptors, metadata integration, transport-specific transfer engines and lifecycle tests.
5. [#194 — Setup and sync](https://github.com/svoltolini/gumbo/issues/194): provider choice/discovery, all-platform setup, credential storage, personal/family sync and old-client guards.
6. [#195 — Watch delivery](https://github.com/svoltolini/gumbo/issues/195): direct WebDAV downloads, iPhone-to-Watch SMB file transfers, progress/ownership/revocation tests.
7. [#196 — Safe maintenance](https://github.com/svoltolini/gumbo/issues/196): permission-aware conditional tag replacement and reviewed exact-file album deletion, including partial failure recovery.
8. [#197 — SMB provider](https://github.com/svoltolini/gumbo/issues/197): integrate the selected dependency, secure reads/streaming/transfers, reconnect and interoperable server fixtures.
9. [#198 — Certification and release](https://github.com/svoltolini/gumbo/issues/198): named QNAP/ASUSTOR/TrueNAS/Unraid configurations, physical-platform acceptance, privacy/support docs and staged TestFlight rollout.

Dependencies: foundation precedes adapters and setup; media integration depends on the read contract; Watch and writes depend on relevant provider capabilities; SMB implementation depends on its feasibility decision. Automated fixtures start with each implementation issue. The certification issue owns the consolidated real-device matrix, not all testing at the end.

Ship the QNAP/WebDAV milestone separately once its applicable requirements pass. Keep SMB and remaining certifications open on the epic. No additional provider is advertised on gumbo.one or App Store metadata before that specific configuration is accepted.

## Verification and definition of done

- Migration: legacy catalogue/CloudKit/Watch/Keychain fixtures keep Synology IDs, favourite and playlist references, downloaded memberships and real local files. Unknown/future provider data fails without network requests or purging data.
- Isolation: same host with different protocols, WebDAV base paths, SMB shares/domains or accounts cannot exchange credentials, artwork, downloads or family state. Profile/source changes cancel stale work.
- Files: non-ASCII/reserved characters, long and case-sensitive paths, root traversal, symlinks, malformed XML, paging/partial responses, denied folders and large catalogues. Failed scans preserve prior data.
- Media: MP3/AAC/FLAC and existing supported formats, head/tail metadata, oversized artwork, absent/wrong ranges, changed file versions, seek near EOF, corrupt files, expired credentials, offline interruption and recovery.
- Transfers: relaunch/background callbacks, sleep, metered/offline networks, changed credentials, insufficient storage, duplicate ownership, cancellation, partial-file validation and late completions after deletion/logout.
- Writes: read-only accounts, conditional conflict, locks, partial `207`, lost acknowledgements, interrupted staging/rename, rollback and exact-file scope. Destructive tests only on disposable reviewed libraries.
- Sync: mixed old/new app versions, personal Keychain off/on, family owner/member/revoked access, changed provider credentials, downloaded membership without automatic audio downloads.
- Networks: local-network permission denial and recovery, IPv6, VPN transitions, certificate mismatch/expiry, redirects across origins and repeated rejected credentials without account-lockout retry loops.
- Devices: signed iPhone, iPad, Mac, Apple TV and paired physical Watch, plus CarPlay acceptance where applicable. Test VoiceOver, Dynamic Type, keyboard/focus, narrow/large layouts, dark mode and Reduce Motion.
- Release: complete model/firmware/protocol/auth/permission/network/platform evidence; update setup and troubleshooting docs, privacy disclosures and feature claims. Keep unsupported capabilities hidden with an understandable explanation when relevant.

Completion requires passing unit/contract tests, signed platform builds, provider-backed physical acceptance, reviewed dependency notices, a staged TestFlight release and truthful published compatibility documentation. A successful build, simulator run or protocol checkbox alone is insufficient.

## Primary technical references

- [QNAP QTS 5.2 WebDAV setup](https://docs.qnap.com/operating-system/qts/5.2.x/en-us/configuring-webdav-settings-CDDF133D.html), [ASUSTOR WebDAV setup](https://www.asustor.com/en/knowledge/detail/?group_id=1002&id=), [TrueNAS WebDAV application](https://apps.truenas.com/resources/deploy-webdav/), [Unraid shares](https://docs.unraid.net/unraid-os/using-unraid-to/manage-storage/shares/).
- [WebDAV RFC 4918](https://www.rfc-editor.org/rfc/rfc4918.html), [HTTP semantics and ranges RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html).
- [Apple resource loading](https://developer.apple.com/documentation/avfoundation/avassetresourceloader), [authentication challenges](https://developer.apple.com/documentation/foundation/handling-an-authentication-challenge), [URLSession protocolClasses limitations](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/protocolclasses).
- [Apple Watch networking restrictions](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos), [Watch background requests](https://developer.apple.com/documentation/watchos-apps/making-background-requests), [paired-Watch file transfer](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:)).
- [AMSMB2](https://github.com/amosavian/AMSMB2), [libsmb2](https://github.com/sahlberg/libsmb2), [SMBClient](https://github.com/kishikawakatsumi/SMBClient) (verify the dependency decision against upstream at implementation time).

# SMB dependency and security policy

## Decision, 2026-09-21 (#191, #197)

Use `Packages/GumboSMB`, a pinned, explicitly dynamic build of [libsmb2](https://github.com/sahlberg/libsmb2) at `557e837d3e00636b543f17ba1b9bdf872fa1644d`. Gumbo's Swift adapter is read-only and owns each C context on a serial background queue. It exposes the existing `RemoteFileDrive` operations and bounded random reads; passwords never enter URLs. iOS, macOS and tvOS link the library. watchOS has no C dependency and uses the phone relay for SMB files.

[AMSMB2 4.0.3](https://github.com/amosavian/AMSMB2/tree/4.0.3) was evaluated: its dynamic packaging is useful, but its public API does not require signed SMB2 and its pinned libsmb2 (`aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03`) predates the current mandatory-signature checks. Taking only its wrapper would still require a source fork and policy surface. [SwiftSMB](https://github.com/RuiNelson/SwiftSMB) currently requests Swift tools 6.4, above this project's 6.2 package baseline. The small direct C adapter avoids a second wrapper fork while retaining the upstream source and license.

## Policies

`encrypted` is the default and requires authenticated SMB3 encryption for post-authentication traffic. `signed` allows authenticated SMB2/3 with mandatory signing and accepts server-required encryption. There is no SMB1, guest/anonymous, plaintext HTTP or weaker-policy retry. Domain-qualified accounts use `DOMAIN\user`; a share is selected explicitly. SMB3 encryption is preferred for remote/VPN use. SMB2 signing protects integrity, not confidentiality.

Current upstream checks missing/incorrect signatures and the final authenticated setup signature, but review found that its receive path matched only message ID before using an untrusted wire command for handshake exemptions. The Gumbo patch matches the response command to the queued request before payload parsing and derives exemptions from that queued command. The opt-in policy additionally rejects guest/null session flags, requires a valid session key, and enforces encryption on inbound post-authentication packets when requested, including header-only pending responses. The patch also retains signature verification when negotiation selects encryption. Negotiation/initial session setup cannot use an established session key; final setup is checked separately. An unsigned interim STATUS_PENDING is allowed in signed mode, but is never exposed as file data and its eventual completion must authenticate. AEAD validation remains upstream's implementation.

Apple builds always use the platform `arc4random_buf` CSPRNG for the client challenge, preauthentication salt, GUID and CCM nonces (and the bundled server challenge). The platform selector is independent of generated feature configuration; predictable `random`/`srandom` code is not compiled into the Apple path. This corrects issue #207: the original Apple config omitted the strong-source feature macro. The API has no recoverable failure result, so there is no weaker RNG retry. Encryption algorithms/key sizes are unchanged. Non-Apple upstream fallback code remains unmodified and is not a supported Gumbo build target.

`gumbo-policy.patch` records all changes from the pinned upstream files, including module packaging. A library update must re-review these hook locations and run both policy regressions and the real Samba fixture. Neither URL parsing nor fixture success substitutes for cryptographic/protocol review.

## Limits and cancellation

Each range request is limited to 8 MiB; artwork downloads to 64 MiB. Offline downloads use one protected read handle and [verified persisted checkpoints](SMB-RESUME.md). C reads are capped to 1 MiB/server limit per call. Operations have a 10-second network timeout, check task cancellation before/after the blocking operation and between chunks, and retry one disconnected/timed-out read with the same policy. Protected offline transfers use a separate context so they do not hold up playback or seeking. The C global context registry is synchronized across these independent queues; a regression exercises 48,000 parallel context lifetimes. Cancellation never destroys a C context in use. It can therefore take until the current blocking call finishes. C directory enumeration fails completely before exceeding 100,000 entries, 4,096 pages, 64 MiB of reply data or 60 seconds, with cancellation checks between pages/entries; a current network call can still take up to its 10-second timeout. Directory record sizes, name lengths and next-entry offsets are validated before decoding, and duplicate names are refused; traversal paths and directory listings containing child separators are rejected; reported symlinks are excluded. SMB share/server permissions remain the boundary for server-side links or aliases.

## Verification and distribution gates

- `Packages/GumboSMB/Tests/run-security-tests.sh`: actual linked CSPRNG success/imports, intercepted production entropy callers with legacy-generator traps, stale-feature-config compilation, and 48,000 concurrent context lifetimes; 21 actual receive-state-machine cases (forged command exemptions, signatures, AEAD, pending replies and valid handshakes/notifications), plus actual directory decoder short-buffer/name/offset and budget boundaries. No NAS or real credentials are used.
- `SMBDriveTests`: settings, path and size bounds, literal Unicode names, cancellation, malformed/changed data, guest/null flags, unsigned/unencrypted packet policy.
- `SMBLocalIntegrationTests`: opt-in isolated Samba fixture, actual encrypted/signed connections and authenticated range reads, concurrent requests, EOF, reconnect, bad password, missing files, SMB2-only encryption refusal, and guest-mapping refusal. See `Tools/SMBReadFixture/README.md`.
- `SMBResumeIntegrationTests`: protected open blocks competing SMB writers/deletion but permits readers; releasing it permits writes again. Cancellation leaves a partial file; a new authenticated session correctly replaces a same-size changed representation. Unit and DownloadManager tests cover every-byte verification, process restoration, cancellation, late completion, access changes, explicit removal and deletion scope.
- Verify each signed Release archive contains the separate GumboSMB framework and the app references it dynamically. Verify the Watch app contains no GumboSMB binary. Repeat on export; a package declaration alone does not prove embedding or signing.
- Include `NOTICE.md` and `LICENCE-LGPL-2.1.txt` in the app's third-party notices, publish matching modified library source/build inputs with the release, and verify the applicable LGPL relinking/modification permissions and distribution conditions. See [GNU LGPL 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html), especially sections 2, 4 and 6. This decision is an engineering record, not a legal or App Store approval.
- Physical-device SMB/NAS interoperability, background transfers and encrypted seeking still require end-to-end acceptance with real devices. No real NAS files were changed by the fixture.

## Apple runtime proof, 2026-09-21 (before entropy correction)

This historical proof exercised I/O and packaging but did not detect the entropy configuration defect; its binaries are superseded by the corrected evidence below.

The isolated [Apple runtime probe](../Tools/SMBReadFixture/AppleRuntime/README.md) passed on iOS 26.5 simulator (23F77), tvOS 26.5 simulator (23L470), and native macOS 27.0 (26A428). Each executed encrypted SMB authentication, Unicode listing, stat, byte-exact range reads and protected full-prefix correction/copy against the disposable Samba fixture. Each app passed deep/strict signature verification; its embedded GumboSMB framework passed strict verification and appeared in the executable's dynamic dependencies. The fixture apps use ad-hoc signing; the Mac harness is unsandboxed. This is runtime dependency/I/O proof, separate from production app permissions, distribution signatures, physical devices, other NAS firmware, and background lifecycle acceptance.

The local `work/smb-runtime-proof/runtime-evidence.json` contains all three runtime reports, executable/framework SHA-256 hashes, signature output and source hashes. `ios-build.log`, `tv-build.log` and `mac-build.log` record the successful Release harness builds. The source patch for this proof is `e370ac4539eab7f3e8842aa215c2b7d0c383d591b17e210eb1c5d5a4e4999c33`; it applies cleanly to the pinned upstream source. The checked-in probe and commands above reproduce the calls; its only differences from the captured harness are portable local package/output paths. No credentials beyond the fixture's public test-only account were used. The fixture containers and isolated apps were stopped after verification.

## Secure entropy correction and refreshed proof, 2026-09-21 (#207)

The old compiled Mac library returned `-1` from `smb2_random_bytes`, proving it selected the weak fallback despite successful encrypted I/O. The corrected library returns `0`, imports `arc4random_buf`, and imports neither `random` nor `srandom`. This check is required alongside successful protocol tests; network success alone does not establish secure random generation.

`Packages/GumboSMB/Tests/run-security-tests.sh` passed its actual dynamic-library control, test-only production-source entropy routing (client challenge/salt/GUID and CCM nonce), deliberately missing feature-macro compile, 21 socket receive scenarios, directory decoder/budget checks and 48,000 parallel context lifetimes. Source review confirmed the bundled NTLM server challenge also uses the same helper; Gumbo does not run that server path. Device-SDK objects compiled at the package minimums for arm64 iOS 26.1, tvOS 26.0 and macOS 26.0, each importing the CSPRNG and no legacy RNG. The opt-in isolated Samba Swift run passed 54 tests in 8 suites, including resume/download lifecycle regressions:

```sh
Packages/GumboSMB/Tests/run-security-tests.sh /absolute/scratch/smb-security
python3 Tools/SMBReadFixture/prepare.py
docker compose -f Tools/SMBReadFixture/compose.yaml up --build -d
GUMBO_SMB_LOCAL_FIXTURE=1 swift test --package-path Packages/GumboCore --scratch-path /absolute/scratch/smb-core --filter 'SMB|ForegroundCheckpoint|ForegroundDownload|ServerDeletedDownloads'
docker compose -f Tools/SMBReadFixture/compose.yaml down
```

The [same Apple probe](../Tools/SMBReadFixture/AppleRuntime/README.md) was rebuilt in Release and rerun against the generated encrypted Samba fixture on iOS 26.5 simulator (23F77), tvOS 26.5 simulator (23L470), and native macOS 27.0 (26A428). All three passed encrypted authentication, Unicode listing, stat, byte-exact bounded reads and protected full-prefix correction/copy; all app/framework signatures verified and all embedded frameworks imported only `arc4random_buf` for entropy. Framework SHA-256 hashes:

| Platform | Corrected framework SHA-256 |
|---|---|
| iOS simulator | `3d2d9b97e37fd84de74ab34d4750fe0d9c35042ed5bfc457c14528afa8ecd893` |
| tvOS simulator | `581b92ea3da00a85dcab42a85b1a0a7320609ef0f98197ebef207386d09f3fc8` |
| Native macOS | `e42a09e3171aef5ecd5f80952ab4302dabb725c6ec632f878173790922653f69` |

The corrected source patch SHA-256 is `455b6d4255481bbf83983b61d142757b70f19e96cc83a29c5ec0adc4cb85b5c0`, verified to apply to the pinned upstream commit. Local evidence is `work/smb-runtime-proof/entropy-runtime-evidence.json`, `entropy-{ios,tv,mac}-build.log`, `/tmp/gumbo-smb-entropy-security.log` and `/tmp/gumbo-smb-entropy-core.log`. These remain isolated ad-hoc harnesses (Mac unsandboxed), not App Store distribution archives, physical-device/real-NAS certification, background-lifecycle acceptance, or encryption/export approval. No real NAS or user credentials were used.

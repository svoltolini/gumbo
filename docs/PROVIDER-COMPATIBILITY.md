# Provider validation evidence

This records development evidence for #155 and its child issues. It is not a new public claim that every NAS brand or device configuration is certified. Named QNAP/ASUSTOR/TrueNAS/Unraid hardware and paired physical-device acceptance remain open.

## Server fixtures

| Configuration actually tested | Evidence | Limits |
| --- | --- | --- |
| Samba 4.17.12 on Debian bookworm, container bound only to Mac loopback, SMB3 encryption required, mandatory signing, named local test account, read-only generated files | `SMBLocalIntegrationTests`: connect, root/list/stat, literal Unicode/reserved-character name, random reads, EOF, bounded cover download, parallel requests, reconnect, bad-password rejection and missing-path mapping | Synthetic bytes, not real NAS firmware or physical-device playback |
| Same Samba image limited to SMB2.1, mandatory signing, encryption off | Signed connection/read succeeds; encrypted policy refuses connection without downgrade | No SMB1 or guest support is advertised |
| Same Samba image with unknown-user guest mapping enabled | The authenticated client never accepts the mapped login; the server or client rejects it | C policy also directly rejects guest/null flags |
| Native socket-pair packet fixture, no IP networking | Actual C receive parser rejects forged command-based signing/encryption bypasses, bad MAC/AEAD and plaintext under encrypted policy; accepts matching signed/encrypted reads, interim pending, setup/negotiation and authenticated notifications | This is focused regression evidence, not a complete cryptographic audit |
| Native directory decoder fixture | Truncated headers/names, malformed offsets, embedded NUL, overflow and resource-budget boundaries fail before an unsafe result | The C enumeration cap fails the whole listing; it never returns a partial catalogue as complete |
| HTTPS WebDAV adapter fixtures | `WebDAVTests` inject controlled URLSession responses to exercise auth headers, redirects, paths, complete depth listings, XML bounds and byte ranges | No branded hardware/firmware or physical Watch HTTPS transfer is certified by this fixture |
| Optional metadata helper | Its separate MP3/FLAC/M4A fixture suite and safeguards are documented in [the helper README](../Tools/GumboTagService/README.md); the [measured transfer comparison](METADATA-HELPER-BENCHMARK-2026-09-21.md) avoided over 99.97% of body bytes but was slower on loopback | No real NAS install, filesystem/ACL or deployment acceptance yet |
| WsgiDAV 4.3.3 filesystem provider, loopback temporary files | [Conditional mutation experiment](../Tools/WebDAVWriteFixture/README.md): ordinary stale DELETE refused, but destination MOVE condition, external same-stat rewrite, injected final-move failure and replacement-before-unlink did not preserve the reviewed original | This implementation does not qualify for generic native writes; WebDAV/SMB mutation capabilities remain disabled |

The reproducible Samba recipe is [Tools/SMBReadFixture](../Tools/SMBReadFixture/README.md). It contains only generated test files and a test-only password. All three ports bind to `127.0.0.1`; the fixture never reads or changes a real NAS.

## App integration regression evidence

The final Release core suite passed **697 test functions across 54 suites** on 2026-09-21. This includes malformed CloudKit provider-field coverage (both wrong data type and unknown schema version) and foreground connection revocation on sign-out, server change and profile deactivation. Six delayed-read context cases verify that old bytes cannot publish into a new retry, queued songs cannot use a revoked drive, and completed downloads remain available. The final implementation batches queue persistence so leaving a large download queue does not write one JSON snapshot per song. The tests cover existing DSM identities, provider-scoped credentials, stale sign-ins, source/profile isolation, bounded AVFoundation playback and seeking, changed file versions, download cancellation and ownership, family payloads, and maintenance outcomes. The optional helper passed 14 tests both on macOS and in its restricted Linux container using generated MP3/FLAC/M4A files.

The signed iOS simulator smoke run passed 13 tests and identified one incorrect test assertion: iOS retained an off-screen keyboard accessibility object after it no longer obscured the app. The corrected test checks visible intersection; both focused search tests then passed, including typing, no results, clearing, scrolling and tab isolation. This hardware-keyboard simulator does not establish physical/software-keyboard dismissal. An earlier unsigned test run failed at CloudKit initialization because disabling signing removed the required entitlement; normal simulator signing resolved those launch failures.

The real Samba fixture run above is separate: opt-in server tests are not counted as exercised merely because the ordinary package suite passes. Real HTTPS background-session authentication across process relaunch, physical Watch delivery and named NAS firmware remain acceptance work.

SMB downloads now retain scoped, hidden partial files across interruption/relaunch and verify every retained byte through a new protected read handle before reusing it. This is disk-prefix reuse: it still rereads the prefix over the network and does not claim bandwidth-saving resume. A dedicated transfer connection keeps playback and seeking responsive; a new global-context lifecycle regression covers 48,000 parallel C context lifetimes. Downloads exposes reclaimable interrupted bytes and a clear action that preserves active work and completed songs. The final focused run passed 54 test functions across eight suites, including the actual Samba fixture; the receive, directory and parallel lifecycle C regressions also passed. See [SMB checkpoint guarantees and limits](SMB-RESUME.md). Native WebDAV/SMB mutation primitives remain disabled; the optional server-side helper provides tag edits only, not generic deletion. Those remaining guarantees stay tracked in #196.

The optional `Family.providerConnection` Bytes field was deployed to production and verified by reopening the 15-field Family schema on 2026-09-21; no index or role changes were made. It contains the versioned non-secret configuration; generic records omit the legacy DSM address. Unknown or malformed provider data must retain the last known family and report an error. This additive schema check did not read or write user records. Cross-device validation remains pending, independently of passing payload tests. See [the deployment evidence](CLOUDKIT-PROVIDER-DEPLOYMENT-2026-09-21.md).

## Apple packaging evidence

The final checkpoint/concurrency source also passed signed Release builds of iOS (including embedded Watch/widgets), native Mac and TV, plus 697 core tests. Configuration preflight reports 16 passed and three intentional upload blockers: the iOS/Mac/TV encryption declarations remain pending for the newly bundled SMB cryptography. It is not a fully green release preflight. The earlier archives/exports below retain their original source scope; these new builds are not new TestFlight uploads.

Signed Release builds of iPhone/iPad, Mac and Apple TV passed during integration, including the embedded Watch target. Each main app dynamically links a separate GumboSMB framework, verified by inspecting the Mach-O dependencies. Its embedded framework passed code-signature verification. The Watch executable does not link GumboSMB and contains no GumboSMB framework.

Fresh signed archives and App Store distribution exports passed on 2026-09-21 with Xcode 27.0 (27A266a), after the receive-policy/directory patches and the provider file-version checks. This was a packaging proof using version 1.0/build 202609211143, not an uploaded replacement for that existing build number. A shipping release still needs its own build number and final-source validation.

| Artifact inspected | Archive | Distribution export | Exported payload checks |
| --- | --- | --- | --- |
| iPhone/iPad, with embedded Watch | Passed | IPA passed | Main app dynamically links one signed GumboSMB framework; SiriKit entitlement present; embedded Watch has no SMB linkage/framework |
| Mac | Passed | Signed installer package passed | App dynamically links one signed GumboSMB framework; Mac uses App Shortcuts, not the iOS-only SiriKit media entitlement |
| Apple TV | Passed | IPA passed | App dynamically links one signed GumboSMB framework |

Both archived and unpacked exported apps passed deep/strict code-signature verification. Each SMB framework passed separate strict verification. The packaged core resource contains the full LGPL text, BSD notice and exact source revision. Exported app binary SHA-256 values and individual results are recorded in the local release evidence `provider-distribution-final/package-evidence.json`, beside the six archive/export logs. The local patch checked for this proof has SHA-256 `fd162e8ed5180664fe9a5b739f7b4dd75c669dc335ca7d7b4372a08e02502b66` and applies cleanly to the pinned upstream revision.

The final isolated Samba/SMB/Watch-provider run passed 30 test functions across four suites (including parameterized cases). The 21 receive-parser cases and separate malformed-directory/budget fixture also passed. None of these checks contacted a real NAS, and the loopback containers were stopped afterward.

The core package includes third-party notices as an app resource. The LGPL library source, exact revision, local patch, complete license and rebuild instructions remain in [Packages/GumboSMB](../Packages/GumboSMB/NOTICE.md). Archive/export proof must verify both the separate library and the bundled notice. The engineering decision does not by itself establish all licensing/distribution conditions.

No TestFlight upload was performed for this proof. iOS/Mac/TV no longer inherit the old declaration that the app uses only exempt Apple-provided encryption: libsmb2 includes cryptography of its own. Complete the App Store Connect encryption questionnaire and verify the applicable distribution conditions before uploading this provider release. See [App Review notes](APP_REVIEW_NOTES.md).

## Device and provider acceptance still required

| Scenario | Status |
| --- | --- |
| QNAP QTS/QuTS hero HTTPS WebDAV on a named model/firmware | Pending hardware acceptance |
| ASUSTOR HTTPS WebDAV on a named ADM version | Pending hardware acceptance |
| TrueNAS/Unraid/QNAP/Synology SMB2/3 on named server versions | Pending hardware acceptance |
| Physical iPhone/iPad: login, scan, MP3/M4A/FLAC playback, long seek, lock-screen interruption, offline retry | Pending provider-backed device acceptance |
| Mac: real shared folder, sleep/wake, reconnect, large library and playback | Pending provider-backed device acceptance |
| Apple TV: real NAS, focus navigation, source/profile switch and streaming | Pending provider-backed device acceptance |
| Physical Watch: direct HTTPS WebDAV, SMB phone preparation/transfer, reachability loss, cancellation, relaunch and stale-file rejection | Pending paired-device acceptance |
| CarPlay using the new providers through iPhone playback | Pending physical/simulator route acceptance |
| Generic-provider personal iCloud Keychain and family payloads across different real accounts/devices | Unit/schema evidence is separate; end-to-end acceptance pending |
| Optional metadata helper on a real NAS with its actual ownership/ACL/backup behavior | Pending explicit controlled installation and acceptance |

Apple Watch has no direct SMB socket provider. SMB selection requires a reachable iPhone with Gumbo open while preparing songs; prepared files then transfer for offline Watch playback. HTTPS WebDAV uses direct authenticated Watch downloads. Neither route is certified by a successful Watch compile alone.

See [NAS setup and troubleshooting](NAS-SETUP.md) and [Watch provider behavior](WATCH-PROVIDERS.md). Do not mark certification #198 complete or expand marketing compatibility claims until the named configurations have passed their device journeys.

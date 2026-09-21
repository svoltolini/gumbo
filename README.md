# Gumbo

Gumbo is a native Apple-platform music app for a personal NAS library. It builds a local catalogue, streams or downloads audio from your server, and synchronizes family profiles through CloudKit. The current public TestFlight release supports Synology DSM/File Station; the additional providers in this development checkout are not yet a released compatibility claim.

The repository contains the iPhone/iPad app, native Mac app, Apple TV app, Apple Watch app, widgets, Live Activities, CarPlay scene, and the shared Swift package.

Gumbo now uses a separate app identity, with new bundle IDs, CloudKit container, app group, URL scheme and local storage. It does not update or migrate the previous TestFlight app. See [the identity and distribution checklist](docs/GUMBO-IDENTITY.md) before signing or uploading a build.

## Project map

| Area | Location | Responsibility |
| --- | --- | --- |
| Shared core | `Packages/GumboCore/Sources/GumboCore` | Server providers, indexing, library state, playback, downloads, profiles, and CloudKit |
| Shared widget models | `Packages/GumboCore/Sources/GumboShared` | Widget snapshots, deep links, and Live Activity state |
| iPhone and iPad | `Gumbo` | Main SwiftUI app, setup, library, player, settings, CarPlay bridge, and Watch bridge |
| Mac | `GumboMac` | Native Mac shell, setup assistant, navigation, and player bar |
| Apple TV | `GumboTV` | TV navigation, focus-based UI, setup, and playback |
| Apple Watch | `GumboWatch` | Received catalogue, playlist downloads, and independent local playback |
| Widgets | `GumboWidgets` | Home, downloads, playlists, rediscovery, and download Live Activity |
| Optional metadata helper | `Tools/GumboTagService` | Separately installed service for editing tags on the machine that stores the music |
| Project definition | `project.yml` | XcodeGen targets, capabilities, deployment targets, and versions |

## Server support and development status

**Current public TestFlight:** Synology DSM/File Station. Do not infer support for other NAS brands from network discovery or from the development code below.

**This development checkout:** HTTPS WebDAV and authenticated SMB2/3 adapters add browsing, indexing, playback and downloads. WebDAV requires trusted HTTPS. SMB defaults to encrypted SMB3, with an explicit signed SMB2/3 option; SMB1 and guest access are not supported. WebDAV transport remains read-only; an explicitly enabled NAS helper can add reviewed album deletion. SMB also supports owner-reviewed album deletion and damaged-file cleanup using locked, fingerprinted file handles; native tag replacement and NAS account administration remain unavailable. SMB file preparation is a foreground operation, so keep Gumbo active while downloading.

On Apple Watch, DSM and HTTPS WebDAV use direct server downloads. SMB songs are prepared on a reachable iPhone with Gumbo open, then transferred through WatchConnectivity for local Watch playback. The Watch has no direct SMB client and does not receive the SMB account or password. System-controlled transfer of a prepared file can continue after preparation; this is not background downloading from an SMB server. See [Watch provider behavior](docs/WATCH-PROVIDERS.md).

Automated protocol fixtures and signed packaging checks are recorded in [provider validation evidence](docs/PROVIDER-COMPATIBILITY.md). Named NAS hardware/firmware, physical-device playback, paired Watch transfers and real-account sync still require acceptance. [Issue #155](https://github.com/svoltolini/gumbo/issues/155) and [the provider plan](docs/NAS-PROVIDERS-PLAN.md) track that work; neither code nor a successful build certifies a NAS brand.

## Music, metadata and the optional helper

Music streams from your NAS to your devices and may be downloaded for offline listening. Gumbo does not upload music to a Gumbo-hosted service. The existing Synology tag-editing path downloads a selected music file to the device and uploads the rewritten file back to the NAS. Optional genre suggestions send album and artist names to Apple's music catalogue, not audio or NAS credentials.

The library owner can separately install and enable [the metadata helper](Tools/GumboTagService/README.md) at a trusted HTTPS address mapped to the selected music folder. Gumbo sends that user-operated endpoint relative file paths, requested album/album-artist/genre changes, file fingerprints and job identifiers. It does not upload audio or send the NAS password to the helper: the service reads, stages and rewrites files through its own mounted music folder. Its operator controls that access, job records and logs. The separate helper token stays in the device Keychain and is not included in personal sign-in sync or family CloudKit records.

The helper is optional for listening. It supports tag edits and separately enabled, owner-reviewed album deletion for read-only transports. Deletion defaults to off on both the helper and app, requires an exact-file review, and never removes folders or unrelated artwork. It does not add NAS account-management capabilities. Its GPL-2.0-or-later Python service runs separately and is not linked into the Apple apps. Installation and filesystem/permission behavior on a real NAS remain acceptance work, as described in [the helper's setup, safeguards and license](Tools/GumboTagService/README.md).

## Local checks

```sh
swift test -c release --package-path Packages/GumboCore
xcodebuild -project Gumbo.xcodeproj -scheme Gumbo -configuration Release -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Gumbo.xcodeproj -scheme GumboMac -configuration Release -destination 'generic/platform=macOS' build
xcodebuild -project Gumbo.xcodeproj -scheme GumboTV -configuration Release -destination 'generic/platform=tvOS Simulator' build
```

Run the `GumboUITests` scheme on an iPhone simulator for offline sample journeys: Settings navigation, search typing/scrolling, tab isolation and simulated transport controls. For example, replace `SIMULATOR_ID` with an available iPhone simulator identifier:

```sh
xcodebuild -project Gumbo.xcodeproj -scheme GumboUITests -destination 'platform=iOS Simulator,id=SIMULATOR_ID' test
```

These tests use a sample library and do not verify real NAS audio or downloads. See [the Settings and album-grouping validation](docs/SETTINGS-ALBUM-VALIDATION-2026-09-20.md) for current evidence and remaining release gates.

Keep code signing enabled when launching the app or running UI tests, including in the simulator. `CODE_SIGNING_ALLOWED=NO` is suitable only for compile checks: it drops the CloudKit entitlement and can make the app exit at launch.

Use XcodeGen after changing `project.yml`, and treat `project.yml` as the source of truth for generated project settings.

## Release version policy

The first public version remains `1.0`. For TestFlight iterations, increment `CURRENT_PROJECT_VERSION` across every target and keep `MARKETING_VERSION` at `1.0`.

Passing a build or local simulator check is not sufficient release evidence. Provider-backed flows must be tested with a signed build on the intended devices, including a controlled account for each supported server configuration, CloudKit owner/member accounts, and offline/reconnect cases. New provider and helper work does not change the current public TestFlight feature set until separately validated and released.

Recent feature notes: [optional personal sign-in sync](docs/ICLOUD-KEYCHAIN-2026-09-21.md) and [owner-reviewed album deletion](docs/ALBUM-DELETION-2026-09-21.md).

Voice controls: [Siri and Shortcuts setup](docs/SIRI.md). See [playback feedback and Mac genre-save validation](docs/PLAYBACK-GENRE-SIRI-2026-09-21.md) for implementation evidence and remaining physical acceptance.

## Current audit

The release-readiness review from 14 September 2026 is in [docs/RELEASE-AUDIT-2026-09-14.md](docs/RELEASE-AUDIT-2026-09-14.md). The tracked backlog is in [GitHub Issues](https://github.com/svoltolini/gumbo/issues).

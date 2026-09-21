# Gumbo

Gumbo is a native Apple-platform music app for a personal Synology NAS library. It talks directly to DSM File Station, builds a local catalogue, streams or downloads audio, and synchronizes family profiles through CloudKit.

The repository contains the iPhone/iPad app, native Mac app, Apple TV app, Apple Watch app, widgets, Live Activities, CarPlay scene, and the shared Swift package.

Gumbo now uses a separate app identity, with new bundle IDs, CloudKit container, app group, URL scheme and local storage. It does not update or migrate the previous TestFlight app. See [the identity and distribution checklist](docs/GUMBO-IDENTITY.md) before signing or uploading a build.

## Project map

| Area | Location | Responsibility |
| --- | --- | --- |
| Shared core | `Packages/GumboCore/Sources/GumboCore` | Synology networking, indexing, library state, playback, downloads, profiles, and CloudKit |
| Shared widget models | `Packages/GumboCore/Sources/GumboShared` | Widget snapshots, deep links, and Live Activity state |
| iPhone and iPad | `Gumbo` | Main SwiftUI app, setup, library, player, settings, CarPlay bridge, and Watch bridge |
| Mac | `GumboMac` | Native Mac shell, setup assistant, navigation, and player bar |
| Apple TV | `GumboTV` | TV navigation, focus-based UI, setup, and playback |
| Apple Watch | `GumboWatch` | Received catalogue, playlist downloads, and independent local playback |
| Widgets | `GumboWidgets` | Home, downloads, playlists, rediscovery, and download Live Activity |
| Project definition | `project.yml` | XcodeGen targets, capabilities, deployment targets, and versions |

The only supported server provider in the current implementation is Synology DSM/File Station. Bonjour discovers HTTP and SMB-advertising devices, but Gumbo is not an SMB client.

Additional providers are planned in [#155](https://github.com/svoltolini/gumbo/issues/155): [the implementation plan](docs/NAS-PROVIDERS-PLAN.md) prioritizes QNAP over HTTPS WebDAV, then SMB2/3 and broader NAS validation. These are planned capabilities, not released compatibility claims.

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

Use XcodeGen after changing `project.yml`, and treat `project.yml` as the source of truth for generated project settings.

## Release version policy

The first public version remains `1.0`. For TestFlight iterations, increment `CURRENT_PROJECT_VERSION` across every target and keep `MARKETING_VERSION` at `1.0`.

Passing a build or local simulator check is not sufficient release evidence. Provider-backed flows must be tested with a signed build on the intended devices, including a controlled Synology account, CloudKit owner/member accounts, and offline/reconnect cases.

Recent feature notes: [optional personal sign-in sync](docs/ICLOUD-KEYCHAIN-2026-09-21.md) and [owner-reviewed album deletion](docs/ALBUM-DELETION-2026-09-21.md).

Voice controls: [Siri and Shortcuts setup](docs/SIRI.md). See [playback feedback and Mac genre-save validation](docs/PLAYBACK-GENRE-SIRI-2026-09-21.md) for implementation evidence and remaining physical acceptance.

## Current audit

The release-readiness review from 14 September 2026 is in [docs/RELEASE-AUDIT-2026-09-14.md](docs/RELEASE-AUDIT-2026-09-14.md). The tracked backlog is in [GitHub Issues](https://github.com/svoltolini/gumbo/issues).

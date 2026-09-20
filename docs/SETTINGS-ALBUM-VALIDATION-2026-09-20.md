# Settings and album grouping — 20 September 2026

Version: **1.0 (202609201659)**. Tracked implementation: #130, #131 and #132.

## Result

Settings now uses native grouped forms with neutral symbols. The overview leads to focused pages for appearance, library, music server, profiles/family and privacy. Metadata refresh, title formatting, genre names, recovery and diagnostics are in **Advanced Settings**. Mac retains its category sidebar. Blue remains the action/selection accent. This follows the focused approach in [Apple's Settings guidance](https://developer.apple.com/design/human-interface-guidelines/settings).

Album grouping now reconstructs physical folder membership before applying tags, allowing cached splits to heal during an ordinary **Update Library**. When a folder identifies an album, varying song-level album-artist credits do not split that release. A majority/common artist is retained; compilations use Various Artists. Track credits are preserved. Different artists' identically named albums in separate folders, and distinctly tagged albums in a mixed folder, remain separate. This is conservative folder/tag grouping, not an instruction to rewrite the user's music files.

Recent album history follows surviving tracks when album IDs change, without duplicate entries or cross-source remapping. Favourites and playlists use unchanged track IDs. Intermediate metadata regrouping now runs away from the main actor, with the same artwork scope and cancellation boundary as the final result.

## Verification

| Check | Result |
| --- | --- |
| Full Release core suite | 435 tests, 26 suites passed |
| Album regressions | Guest track, compilation ties, missing album-artist tags, separate same-title albums, mixed folders, multiple discs, prefixed folder names, repeat regrouping, favourites and recent history |
| Local catalogue replay | All 4,817 track IDs retained; unique album IDs; A Radiant Sign becomes one 13-track Nils Hoffmann album while retaining the opening track's joint credit |
| iPhone simulator UI suite | Five journeys passed: Settings/Advanced navigation, every tab while scrolling, search typing/keyboard dismissal/no-results/clearing, album opening and simulated play/pause/next across tabs |
| Large text and appearance | Both Settings navigation tests passed at Accessibility Extra Large on iPhone; iPad mini Settings overview inspected in light and dark mode at the same text size |
| Release configuration preflight | 22 checks passed; package tests were run separately |
| iPhone Release build | Signed app, embedded widgets and Watch built successfully; matching versions and signature verified |
| Mac Release build | Passed with signing disabled |
| Apple TV Simulator Release build | Passed with signing disabled; only the expected App Intents extraction notice for a target without AppIntents |
| Naming and patch hygiene | No old-name text in source/docs; whitespace validation passed |

The catalogue replay used a private local snapshot. No personal catalogue, NAS address, credential, music file or artwork was committed. Grouping took about 0.45 seconds locally; this is not a physical-phone benchmark.

The UI tests use the built-in sample library and Debug simulator fixtures. They do not prove audio output, actual downloads or provider connectivity. The keyboard test uses a drag starting in visible results and ending through the keyboard; swiping the full collection frame can hit the keyboard instead of the list. Settings tests scroll to lazily created rows, including at accessibility text sizes.

## Repeatable checks

Run the core suite:

```sh
swift test -c release --package-path Packages/GumboCore
```

Run the `GumboUITests` Xcode scheme on an available iPhone simulator. The tests navigate the real SwiftUI screens using sample data; they do not require a NAS. The regular `Gumbo` build/archive scheme remains available.

## Remaining release gates

- **#118:** explicit Watch/distribution provisioning, new App Store Connect identity, production CloudKit and distribution/TestFlight validation.
- **#119:** published support/privacy URLs and current App Store review/privacy metadata.
- **#123:** signed physical-device acceptance: real playback/seek/background behavior, downloads/offline/reconnect, CloudKit family accounts, Watch, widgets, CarPlay and TV remote navigation.

The device checklist now describes download Live Activities and the actual Diagnostics location. App Review notes describe static Apple TV banner artwork. Passing these automated checks is not a public-release sign-off.

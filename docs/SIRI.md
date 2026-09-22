# Siri and Shortcuts

## Implemented baseline

On iPhone and iPad, open **Settings → Siri & Shortcuts → Enable Siri**. After setting up the server and opening a profile, ask “Play [song name] by [artist] in Gumbo Music.” Albums, artists and playlists can also be named. Gumbo asks for a choice when the same title identifies several recordings; an unknown title does not start unrelated music.

On iPhone, iPad and Mac, **Play Music** is available to the Shortcuts app. Say “Play music in Gumbo Music” and name the music when asked, or create a shortcut with a selected song or collection. The App Shortcut opens Gumbo. Native SiriKit media requests are iOS-only because Apple's media intent types are unavailable on macOS. The newer MediaIntents search APIs require OS 27, so they are not part of this OS 26-compatible baseline.

The active profile must be open. A server connection is needed unless the complete requested collection is downloaded to this device. A profile change, server change, sign-out or newer playback command invalidates a pending request. If the library updates during name or saved-identifier lookup, Gumbo resolves a fresh snapshot (at most three attempts) within the same source, folder, profile, session and connection. It never returns stale matches. Changes after selection still invalidate playback. A request rejected by Siri can be retried after opening Gumbo and checking the connection. This baseline replaces the queue; “play next,” playback-speed changes and multiple separately requested items are not supported.

## Privacy

Apple handles the voice request according to the person's Siri settings. Gumbo searches its local library snapshot and returns matching music names for that request. It does not donate the complete catalogue or listening history to Siri, and does not send NAS credentials or music files in intent responses. Saved shortcut identifiers are opaque hashes scoped to the server, root folder and profile; they cannot select a same-named file from another library or profile.

## Packaging and acceptance

- The iOS app declares `INPlayMediaIntent`, the Music category, the Siri entitlement and a Siri usage description. The Apple App ID and signing profile must also include Siri before device distribution.
- iOS handles requests in the main app delegate, sharing the existing player, profile and connection state. There is no separate process with a second NAS login or player.
- iPhone/iPad and Mac refresh App Shortcuts registration at startup, after installing the voice controller. The entity query still returns no suggested catalogue entries. This follows Apple's [App Intents sample](https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents); bundled metadata alone is not a runtime registration check.
- Play Music includes its required Music entity in its parameter summary. Without that summary, Spotlight cannot present the required input and excludes the action. The signed Mac and iOS metadata now contains `Play ${music}` with `music` in its parameter identifiers, following Apple's [Shortcuts and Spotlight guidance](https://developer.apple.com/videos/play/wwdc2025/260/). This packaging check is separate from installed-app discovery and spoken dispatch.
- Automated tests exercise title ambiguity, artist/album filters, literal titles containing “by,” duplicate playlist entries, offline downloads, unavailable servers, cancelled tasks, newer playback commands, and profile/source/root/connection/content changes during a request.
- Before closing GitHub issue #189, test a signed build on a physical device: enable/deny Siri, exact song, duplicate titles and spoken selection, album/artist/playlist, no match, cold launch, locked profile, offline downloaded music, unreachable NAS and a manual playback action while Siri waits. Verify Mac Shortcuts separately. Compilation and provider capability configuration do not establish successful spoken Siri routing.

Apple references: [in-app media requests](https://developer.apple.com/documentation/sirikit/improving-siri-media-interactions-and-app-selection), [supported in-app intents](https://developer.apple.com/documentation/bundleresources/information-property-list/inintentssupported), [app media categories](https://developer.apple.com/documentation/bundleresources/information-property-list/insupportedmediacategories), [Siri authorization](https://developer.apple.com/documentation/sirikit/requesting-authorization-to-use-siri), and [newer audio search APIs](https://developer.apple.com/documentation/mediaintents/responding-to-audio-search-and-playback-requests).

### Mac development-copy check, 21 September 2026

The startup registration call was missing and has been added. Signed Release Mac and iOS builds and all 11 voice-resolution regressions passed. The Mac runtime now reaches `Updating AppShortcut parameters`, but its subsequent registration request fails. Shortcuts still does not list Gumbo on this development machine. Launch Services resolves the bundle identifier to the older installed TestFlight copy in `/Applications`, rather than the tested development copy. Temporarily unregistering that copy exposed another older build; the original registration was restored. Multiple copies with the same identifier/build make this an inconclusive installed-app test, not a successful Siri acceptance result. Retest a single installed final build through Shortcuts and spoken Siri before closing #189.

### Installed Mac follow-up, 22 September 2026

After replacing the installed app with the signed development build, Shortcuts listed **Play Music**. Its entity picker distinguished the album *Breathing* from same-named songs. A saved album shortcut successfully dispatched playback while Gumbo was open, but cold launch exposed a real race: a library revision changed during entity resolution and the request failed before `perform` with “Your library or profile changed.”

Lookup now retries with a fresh snapshot only while its original access context remains unchanged. Eighteen voice tests passed, including startup updates, removed/renamed results, bounded retries, cancellation, access changes during retry and manual playback superseding the request. Signed Release Mac and iOS/embedded Watch builds passed. Development build `202609221423` was installed on the Mac with Production CloudKit and existing data retained. The saved shortcut then passed two cold launches: the correct first song played, the clock advanced, Pause worked, and Shortcuts returned to Run without an error. See [the device checkpoint](DEVICE-CHECK-2026-09-22.md).

This verifies installed Mac Shortcuts discovery, entity selection and cold dispatch. It does not establish spoken Siri, every request kind, offline or locked-profile behavior on physical devices. Those acceptance cases remain open in #189/#123.

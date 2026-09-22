# Development-device checkpoint — 21 September 2026

This records observed checks for #123 and #189. It is not a TestFlight upload or full platform acceptance.

The [22 September follow-up](DEVICE-CHECK-2026-09-22.md) supersedes the installed-Mac and Mac Shortcuts limitations below.

## Source and installation

- Maintenance source `ee19a071e1e9d217a6ddd94d546d63e0a9a95a5f` has the same tree as merged main `2ba92ad3816cc41ca3770a0be2553575263455e8` (PR #212).
- Its signed development iPhone app was installed over the existing Gumbo bundle on an iPhone 17 Pro Max running iOS 27.0. The app explicitly uses Production CloudKit, retains Siri/CarPlay entitlements and has a verified signature. Its launch succeeded and a later process query found it running. No sample/reset launch arguments were used.
- The Mac test copy runs on macOS 27.0 with Production CloudKit and the existing application data. The original TestFlight app in `/Applications` remains unchanged; it is protected against replacement. A backup was also retained. The exact running development executable was verified independently.
- These artifacts retain version 1.0/build 202609211143 and record source provenance separately. They are different code from the public beta with that number and must not be presented as a new TestFlight release.

## Observed Mac checks

| Check | Result |
| --- | --- |
| Open existing library after launching the development copy | Existing albums/profile retained; no repeat setup requested |
| Search for Breathing, select Albums, open the result | One matching album; navigation and song rows displayed |
| Start Little Lights from the album | Loading changes to Playing; playback clock advances; current song is emphasized and has a state marker |
| Album Pause, then album Play | Current song pauses and resumes at about 1:02 rather than restarting; row and transport states agree |
| Seek to 65% | Position updates to about 3:30 of 5:24 |
| Next song | Next row changes from Loading to Playing and its clock advances |
| Pause before leaving playback | Player and album controls return to Play; active row remains marked Paused |
| Open Settings, Siri & Shortcuts, Advanced Settings and Faster Tag Editing | Screens remain responsive; helper/deletion opt-ins remain off; no helper token or configuration submitted |
| Open Profiles & Family | Existing profile appears; Family Sharing reports Up to date. This alone does not prove cross-device convergence |

The playback observations are transport/UI evidence, not an independent confirmation of audible output. No real music tags or NAS files were changed or deleted. Genre-write reproduction remains documented separately; the original reported process exit is still awaiting affected-device confirmation.

## Observed iPhone checks through Mirroring

The owner authorized Mirroring and authenticated on the Mac. Its connection initially interrupted, then reconnected successfully. Notification forwarding was declined.

| Check | Result |
| --- | --- |
| Open Gumbo and cold relaunch after playback | Library appears with the existing profile/catalogue; no repeat setup or automatic player sheet |
| Open Breathing and start In Memoriam | Album control becomes Pause and the song gains a playing marker; the player opens only when the mini player is tapped |
| Player progress and seek | Clock advances; seeking moves to roughly 3:26 of 6:29 and progress continues |
| Pause and dismiss player | Album and mini-player controls become Play; song remains marked paused |
| Search for breathing | One album and matching songs appear |
| Search for a nonexistent fixture name, clear and cancel | No Results is shown; clearing/cancelling and returning to Library work |
| Open Settings and Advanced Settings after relaunch | Existing profile and downloaded storage remain; maintenance rows and diagnostics are reachable |
| Enable Siri | Apple's authorization prompt appears; allowing the requested integration returns “Siri is enabled” in Gumbo |

The selected phone album was already downloaded; this does not establish fresh NAS streaming, background downloads or offline-network interruption. Mirroring uses keyboard input and does not prove the software keyboard layout. Automated scrolling moved Advanced Settings but did not move the main Library at several tested positions. Keep the reported Library scroll problem unaccepted until it is reproduced with direct touch and distinguished from Mirroring/nested-scroll input behavior. No real file maintenance was performed.

## Still pending

Spoken Siri, Mac Shortcuts dispatch, direct-touch scrolling/software-keyboard behavior, two-account family behavior, paired Watch, CarPlay, named additional NAS appliances and controlled NAS helper deployment remain separate acceptance checks. See [Siri registration limits](SIRI.md) and [the provider matrix](PROVIDER-COMPATIBILITY.md).

## Follow-up simulator checks

On iOS 27.0, the isolated iPhone 17e simulator passed both `testLibraryPullSettlesAndScrollingWorksDuringSlowScan` and `testSearchTypingScrollingAndClearing` (two tests, zero failures). The production Library view settled after repeated pull-to-refresh gestures while the simulated scan remained active, scrolled vertically, opened/dismissed scan details, and opened the album collection. Search matched the sample query, released the visible keyboard area, scrolled, showed no results for an unknown query and cleared back to Recent Searches. These checks use sample data and do not establish the physical phone's direct-touch behavior or real NAS scan performance.

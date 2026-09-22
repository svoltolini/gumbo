# Development-device checkpoint — 22 September 2026

This follows the [21 September checkpoint](DEVICE-CHECK-2026-09-21.md) for #189 and #123. No TestFlight upload or public release is represented here.

## Mac Shortcuts

- The previously prepared app replacement completed. `/Applications/Gumbo.app` ran the expected signed development binary, with the existing profile and library retained.
- Mac Shortcuts now lists Gumbo's **Play Music** action. Searching *Breathing* distinguishes the album from its same-named song entries.
- A new, functional **Play Breathing in Gumbo** shortcut was created with the album entity; existing shortcuts were left intact. Warm dispatch started *In Memoriam* by Ben Böhmer, advanced its playback clock and responded to Pause.
- The first cold launch reproduced a bug in saved-entity resolution: the local library changed during lookup, resulting in “Your library or profile changed. Please ask again.” Playback did not begin.
- The fix retries lookup against current content at most three times, pinned to the same server/root/profile/session/connection. Every result carries the current revision. Deleted results disappear, genuine access changes fail, and cancellation/newer playback commands retain their priority.
- Signed development build **1.0 (202609221423)** was installed at `/Applications/Gumbo.app`; the preceding app was backed up. Production CloudKit and application data were retained. Source was main `6d29654` plus the voice lookup patch; artifact provenance records patch SHA-256 `e0ef9249c80c66c5166f137f83fd5f65450536a484334a1c0ba44f9b950f0044`.
- **Two subsequent cold launches passed.** Each began after the installed Mac process had exited. Running the saved shortcut launched the exact installed binary, started the correct first song and advanced the clock. Pause returned the transport to Play. The second run explicitly returned the Shortcuts toolbar to Run without an error.

No real NAS tags or files were edited/deleted. Playback observations establish transport/UI behavior, not independent audible-output verification or fresh authenticated background downloads.

## Automated and packaging checks

- Release `VoicePlaybackTests`: **18 tests passed**, including parameterized access-change, cancellation and retry limits.
- Signed Release **GumboMac** and **Gumbo** builds passed; the iOS build includes its Watch app and widget extension.
- Strict signature verification passed for the prepared Mac and iPhone applications. The iPhone app retains Siri and CarPlay entitlements and uses Production CloudKit.
- The updated development iPhone build installed successfully over the existing Gumbo bundle. Launch was then refused because the device was locked, and Mirroring timed out connecting. Installation alone is not a spoken-Siri or physical interaction result; those checks await the owner opening the app.

## Still pending

Spoken Siri and its full request/denial/offline matrix, physical direct-touch scrolling and software keyboard, the original reported genre-save process exit, paired Watch and CarPlay, additional NAS hardware, multi-account family convergence, physical background-transfer tests and real-NAS helper measurements remain separate acceptance gates. France encryption and final App Store review requirements remain tracked in their own issues.

# Engineering checkpoint — 22 September 2026

Follow-up engineering for #199 and #201. No production NAS files were edited or deleted, no NAS helper was installed, and no TestFlight upload is represented here.

## Mac genre-save freeze

A CPU resource diagnostic was found for the installed `/Applications/Gumbo.app`, version 1.0 (202609211143), on macOS 27.0 (26A428). It covers 21 September, 12:40:56–12:43:18, and reports 90 seconds of CPU use during 142 seconds. Its heaviest main-thread stack includes `AppKitProgressView.updateNSView`, accessibility notification delivery, `NSTableViewCellMockElement.accessibilityChildrenAttribute` and SwiftUI/AttributeGraph re-entry. This matches the independently reproduced genre-save freeze fixed in #202. The diagnostic says **Action taken: none**; it does not establish process termination. The full report contains private identifiers and remains local.

The current production genre editor was tested again on the physical Mac with the isolated [native save harness](../Tools/MacGenreFixture/README.md), built against main `65b42db`. The harness generated a three-song album with MP3, FLAC and AAC/M4A files. Clicking Done after changing Ambient to Jazz completed and dismissed the editor. The host displayed one album, three songs and Jazz; its UI heartbeat continued. Reading back all three files confirmed Jazz, unchanged encoded audio and unrelated tags, and no leftover staging files. No network, CloudKit or personal-library write was involved.

Together with the earlier native Save/Return/Stop checks, this closes the engineering investigation of the reproducible save freeze. It does not claim a NAS round trip or explain a separate unobserved process exit. A fresh termination report or different reproduction should be tracked as a new failure.

## Optional metadata helper setup

A slow helper connection check could outlive its settings screen or finish after a newer helper choice. Existing profile/server checks did not cancel these cases, so the old result could persist a token or replace a newer configuration.

The settings screen now owns and cancels its check when it disappears or access changes. The model gives each setup a generation, checks cancellation after responses and before persistence, and invalidates pending checks when the helper is disabled. Regression tests hold an in-process fictional capability response while cancellation, disable, sign-out or a newer setup occurs; late responses cannot enable writes or save credentials. These tests never contact a real service or use a real token.

## Helper filesystem verification

The production helper image and a separate test image were built on Docker Desktop's Linux/arm64 engine. All **28 Python tests passed**, with none skipped, as UID/GID 1000 in a container with no network, a read-only root, dropped capabilities and no privilege escalation. Generated fixtures lived only in an anonymous Linux volume. The added cases verify:

- MP3/FLAC/M4A extended attributes and UID/GID survive replacement.
- A named-user POSIX ACL remains unchanged.
- A non-writable parent fails safely, retaining the exact original and leaving no recovery/staging files.

The same suite passed on the Mac: 26 tests passed and two Linux-only checks were skipped. Reproduction commands are in the [helper README](../Tools/GumboTagService/README.md). Synology-specific ACLs, host architecture, private HTTPS routing and representative LAN/remote timing remain installation acceptance work; these local results are not a claim of a real-NAS speedup.

## Broader validation

All **736 Release core tests in 58 suites** passed, including the new helper lifecycle cases and isolated loopback Samba fixtures. Generated SMB fixture containers were stopped afterward. Signed platform build results are recorded in the associated pull request.

The iPhone is currently disconnected and there is no paired Watch, Apple TV, CarPlay or additional NAS hardware available. Physical acceptance remains separate. The provider candidate is still gated by France encryption documentation and the remaining release checks; it has not replaced the public Synology TestFlight build.

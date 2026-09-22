# Playback feedback, Mac genre saving and Siri

Implementation and local validation for [#188](https://github.com/svoltolini/gumbo/issues/188), [#189](https://github.com/svoltolini/gumbo/issues/189) and [#199](https://github.com/svoltolini/gumbo/issues/199), 21 September 2026. These changes were made after TestFlight build `202609211143`; that existing build does not contain them.

## Album and playlist playback

Collection buttons pause or resume the current song without resetting position, shuffle or queue order. Another collection starts its own queue. Matching includes both the track and NAS source identity. Mac tables and shared album/playlist rows show playing, paused, loading or unavailable state, including a paused song at position zero. An unavailable song exposes a retry through Play instead of being labelled paused.

An isolated native Mac harness hosted the production album view with a sample catalogue and injected playback transport. Without recreating the view, the current row changed between a speaker and pause marker and the header between Pause and Play. The current title remained emphasized. No user catalogue, NAS session or installed app was used.

## Genre-save freeze

The reported Mac process exit had no matching production crash report. A native reproduction did establish a Save freeze at the same transition on macOS 27.0 (26A428): editing rows changed to progress, and AppKit's progress accessibility notification re-entered the SwiftUI List graph. All 1,188 main-thread samples were in the `AppKitProgressView.updateNSView` / accessibility / AttributeGraph cycle.

On Mac, `OperationProgressView` now uses a SwiftUI linear progress style. It retains the progress role, title and count without the native AppKit progress update. Other platforms retain their existing style; tag rewriting and NAS replacement are unchanged.

The same isolated genre editor, sample catalogue and fake read-only drive then passed:

- Clicking Done with the name field focused: progress and the expected read-only result appeared; subsequent accessibility inspection completed in 58 ms.
- Pressing Return: the save started without freezing.
- Stopping while the fake drive waited: the stopped result and Done remained responsive.
- Accessible progress title, role and song count were preserved.

This established the fix for the reproduced UI hang. A later installed-app CPU diagnostic and an actual disposable-file save corroborated it; see the [22 September engineering checkpoint](ENGINEERING-CHECK-2026-09-22.md). No separate process-exit report was found, so the evidence describes a freeze rather than asserting a proven termination cause.

## Siri

See [Siri setup, behaviour and privacy](SIRI.md). iPhone/iPad have a native Siri media handler; iPhone/iPad and Mac have a Play Music App Shortcut. Matching uses local immutable catalogue snapshots. Ambiguous titles need a choice; unknown names do not select unrelated music. Pending requests are invalidated by newer playback commands or changes to profile, source, root, session, connection or catalogue.

Apple's Gumbo App ID has Siri enabled and the existing CarPlay, push, app-group and CloudKit capabilities remain registered. This provider configuration is distinct from signed-device and spoken-command acceptance. Keep #189 open for physical Siri delivery, permission, ambiguity, cold-launch and Mac Shortcuts checks.

## Automated validation

- All **579 Release core tests across 37 suites** passed, including seven added collection-playback regressions and eleven voice-playback tests (with context-change cases).
- The focused playback suite passed 41 tests.
- Native Mac and iOS simulator builds passed; the generated App Intents metadata was present in both relevant app bundles.
- Final Release builds passed for signed iOS (including Watch/widgets) and the TV simulator. The signed iOS binary and refreshed development profile both contain Siri and retain CarPlay; registered media types and generated App Intents metadata were verified.
- Mac native Save/Return/Stop reproduction and live playback-state observation passed.
- Version alignment, property-list syntax and `git diff --check` passed.

The signed iOS check used a development profile and was not uploaded. The merge revision belongs in the linked GitHub issues. TestFlight upload and physical NAS/Siri/CarPlay acceptance are not implied by these local results. No real music files were changed during validation.

## Follow-ups

[#201](https://github.com/svoltolini/gumbo/issues/201) evaluates faster server-side tag edits. The current client still downloads, verifies and uploads replacement files. No NAS helper was installed and no unverified speed improvement is claimed.

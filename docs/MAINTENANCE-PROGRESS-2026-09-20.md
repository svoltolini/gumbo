# Music-file progress — 20 September 2026

Tracked in [#149](https://github.com/svoltolini/gumbo/issues/149). Version 1.0, build `202609202112`.

Find Missing Genres now shows one progress card instead of separate album-spinner, song-progress and Stop rows. It names the current album and song, labels the album position and per-album song count, and uses the adaptive black/off-white accent. Long song names wrap; accessibility text can use as many lines as needed.

A secondary Stop capsule has a minimum 44-point touch target. It immediately changes the heading to “Stopping…” and becomes disabled until the existing cancellation completes. Progress remains visible in the meantime. The same component serves genre edits, album renames, file inspection and reviewed deletion. Deletion keeps an indeterminate indicator because its service does not report a per-file completion count.

The NAS authorization, user confirmations, metadata writer, file inspector, deletion service and partial-result reporting are unchanged. No real NAS file was modified for layout validation.

## Verification

- The final layout passed three UI journeys on an iPhone SE (3rd generation) simulator running iOS 26.5: light appearance, dark appearance and the largest accessibility text size. They verify readable progress state, a reachable Stop control with a 44-point minimum target, immediate stopping feedback, retained counters and the disabled sample-library maintenance gate.
- The final light layout also passed on the 390-point iPhone simulator running iOS 27. Earlier light/dark/large-text checks on that simulator passed before the last button-style refinement.
- Screenshots of the normal, dark and accessibility layouts were inspected. A separate image captures the actual progress card using the native UI test screenshot API.
- Signed Release archives and distribution exports passed for iOS with Watch/widgets, universal macOS and tvOS. Bundle signatures, provisioning, production CloudKit, privacy manifests and the iOS CarPlay entitlement/scene were verified.

The fixtures only appear with `--sample-library --ui-preview --preview-genre-progress` in a Debug simulator build. They render the production component with sample values and a local stopping state, never start a metadata writer, and do not enable sample-library NAS actions. Actual file changes and cancellation remain physical/provider acceptance in [#123](https://github.com/svoltolini/gumbo/issues/123).

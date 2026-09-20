# iCloud recovery and neutral controls — 20 September 2026

Issues: [#146](https://github.com/svoltolini/gumbo/issues/146), [#147](https://github.com/svoltolini/gumbo/issues/147).

## iCloud failure

Build `202609201922` was reported to repeatedly fail when saving a profile, with `recordChangeTag specified, but record not found`. Cached CloudKit system fields survived a missing server record; the old save path retained the rejected revision, so pull-to-refresh retried the same write. Replacing a development installation with TestFlight is a plausible trigger because CloudKit's development and production records are separate; the exact provider-side cause was not independently observed.

On `unknownItem` for a cached revision, Gumbo now pulls current changes before repairing that record's cached metadata. It respects profile tombstones and account/family generation changes, persists the repair, and rebuilds the retry from local profile data. A missing profile's document remains pending even if recovery fails or the app closes. Ordinary network failures retain their valid cloud metadata.

The same review bounds profile/family revision-conflict retries and preserves cleared and encrypted fields during reconciliation. Raw missing-record internals remain in diagnostics; a failed automatic recovery gives a readable retry message.

## Interface

Controls are black in light appearance and off-white (`#F4F4F2`) in dark appearance. Filled controls use the opposite text colour. The shared accent, asset-catalog accent, setup flows, library selections, downloads, Watch actions and widget defaults follow that direction. Blue (`#0826FF`) remains in branding. Existing music artwork, playlist gradients and destructive-action colours are retained.

## Validation

- 464 Release shared-package tests passed across 28 suites, including nine new missing-record/conflict scenarios. These cover current edits, relaunch after an offline retry, cloud deletion, account changes, newer cloud records, bounded retries, ordinary network failures, encrypted family fields and cleared fields.
- Signed Release archives passed for iOS (including Watch/widgets), universal macOS and tvOS.
- All 11 offline iPhone interface journeys passed, covering search, scanning/scrolling, playback presentation, profile photos and Settings navigation. Settings was also visually checked in light and dark appearance, and the light player was inspected.
- Exported distribution bundles passed signature, version, provisioning and privacy-manifest checks. iOS retains the CarPlay audio entitlement and scene; iOS, macOS and tvOS use the production Gumbo CloudKit container.
- Release version is `1.0`; every target uses build `202609202055`.

Automated CloudKit tests use injected provider outcomes and make no live cloud mutations. Actual recovery of the reported iPhone profile must be confirmed after installing the new TestFlight build. Track that device result in [#123](https://github.com/svoltolini/gumbo/issues/123).

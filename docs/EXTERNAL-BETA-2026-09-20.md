# Gumbo Music external TestFlight beta

Live App Store Connect configuration verified on 20 September 2026. Track external acceptance in [#162](https://github.com/svoltolini/gumbo/issues/162).

## Approval verified — 21 September 2026

At **07:14 UTC**, all three builds below reported external state **IN_BETA_TESTING**. The public invitation displayed **View Gumbo Music Beta** and **View in TestFlight**, replacing the earlier not-accepting-testers message. The group had **0 enrolled testers**, with the public link and its **50-person limit both enabled**. These are a point-in-time count and availability check; TestFlight controls current availability.

The website now states that the beta is open and keeps the 50-person limit visible. This confirms public invitation/build availability, not a completed physical installation or NAS playback test. Device/provider acceptance remains in #123.

## Initial submission — 20 September 2026

- App: **Gumbo Music**, Apple ID `6814252548`, bundle `com.samuelvoltolini.gumbo`.
- External group: **Gumbo Founding Testers**, ID `d47be32a-2b1d-477d-a23a-c0e8e1f983f5`.
- Public invitation: https://testflight.apple.com/join/GensWMTh.
- Public link enabled, tester limit enabled, **50 testers**. The limit applies to people joining through the public link; do not add direct invitations expecting this cap to limit them.
- Latest builds attached: **1.0 (202609202112)**, all processed as VALID.
- Feedback enabled. iOS compatibility builds on Apple silicon Macs and Vision are disabled for this group; Mac testers use the native macOS build.

| Platform | Build ID | External status at submission |
|---|---|---|
| iOS, with Watch, widgets and CarPlay | `81abfc0d-e66e-4ba0-8497-2efcba47567e` | WAITING_FOR_BETA_REVIEW |
| macOS | `e72b74bd-1bb3-43b2-8333-55950d0c449a` | WAITING_FOR_BETA_REVIEW |
| tvOS | `e18744bf-eb6e-482e-a267-258f9e7ac117` | WAITING_FOR_BETA_REVIEW |

The three Beta App Review submissions were accepted into Apple's review queue. Existing developer contact and feedback-email details were reused from the previous app record; no contact data or credentials are stored here. Beta description and platform-specific What to Test notes were saved. Automatic tester notification is enabled for the builds.

Review notes disclose that Explore Sample Library supports interface inspection with simulated silent playback (Watch is browsing only). Real audio and downloads require a reachable Synology NAS and that NAS's account. No demo NAS credentials were invented or supplied; Apple can request additional review access through the existing contact details.

At verification, the public invitation reported that the beta was not accepting new testers. Group creation and submission do **not** establish external installation availability. The website links to this invitation and retains an availability note. After Apple approves a build, verify that its external state is testing/approved and the public page accepts testers; update #162 with the observed result. Physical-device and NAS-provider acceptance remain in #123.

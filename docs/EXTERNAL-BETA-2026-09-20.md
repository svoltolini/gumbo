# Gumbo Music external TestFlight beta

Initial external-beta configuration was completed on 20 September 2026 and tracked in [#162](https://github.com/svoltolini/gumbo/issues/162). Current distribution and remaining physical acceptance are recorded separately below.

## Current release verified — 21 September 2026, 11:33 UTC

App Store Connect reports **1.0 (202609211143)** from main `c6313140709805ac4361ed410aac5c0441bef063` as **VALID / IN_BETA_TESTING** internally and externally on every shipping platform. Mac's earlier `WAITING_FOR_BETA_REVIEW` state has advanced to testing.

| Platform | Build ID | Internal state | External state |
|---|---|---|---|
| iOS, with Watch, widgets and CarPlay | `b65565c9-660a-4d79-8599-c0cebcca7b3a` | IN_BETA_TESTING | IN_BETA_TESTING |
| Native universal macOS | `aea53282-dc10-4420-b265-d99150a44969` | IN_BETA_TESTING | IN_BETA_TESTING |
| tvOS | `a0412394-1a87-440e-9271-c235bc1c43bc` | IN_BETA_TESTING | IN_BETA_TESTING |

The existing internal and external groups contain these builds; release notes and automatic tester notification are configured. Prior builds and the invitation policy were preserved. The [public invitation](https://testflight.apple.com/join/GensWMTh) remains the website's beta destination. Beta capacity is controlled in TestFlight and is **not displayed in website marketing copy**, as requested by the owner.

Both [gumbo.one](https://gumbo.one/) and its [privacy policy](https://gumbo.one/privacy/) returned HTTP 200 and matched the merged source at this verification. This establishes deployment and TestFlight availability, not physical installation, NAS playback or public App Store approval. Physical/provider journeys remain in [#123](https://github.com/svoltolini/gumbo/issues/123); public-store metadata/privacy work remains in [#119](https://github.com/svoltolini/gumbo/issues/119).

## Earlier approval verified — 21 September 2026, 07:14 UTC

At **07:14 UTC**, all three builds below reported external state **IN_BETA_TESTING**. The public invitation displayed **View Gumbo Music Beta** and **View in TestFlight**, replacing the earlier not-accepting-testers message. The group had **0 enrolled testers**, with the public link and its **50-person limit both enabled**. These are a point-in-time count and availability check; TestFlight controls current availability.

At that point the website stated that the beta was open and displayed its capacity. The owner subsequently requested that capacity be removed from public copy, and the current website follows that request. This earlier observation confirms invitation/build availability at its date, not a completed physical installation or NAS playback test.

## Initial submission — 20 September 2026

- App: **Gumbo Music**, Apple ID `6814252548`, bundle `com.samuelvoltolini.gumbo`.
- External group: **Gumbo Founding Testers**, ID `d47be32a-2b1d-477d-a23a-c0e8e1f983f5`.
- Public invitation: https://testflight.apple.com/join/GensWMTh.
- Public link enabled, tester limit enabled, **50 testers**. The limit applies to people joining through the public link; do not add direct invitations expecting this cap to limit them.
- Builds attached at initial submission: **1.0 (202609202112)**, all processed as VALID.
- Feedback enabled. iOS compatibility builds on Apple silicon Macs and Vision are disabled for this group; Mac testers use the native macOS build.

| Platform | Build ID | External status at submission |
|---|---|---|
| iOS, with Watch, widgets and CarPlay | `81abfc0d-e66e-4ba0-8497-2efcba47567e` | WAITING_FOR_BETA_REVIEW |
| macOS | `e72b74bd-1bb3-43b2-8333-55950d0c449a` | WAITING_FOR_BETA_REVIEW |
| tvOS | `e18744bf-eb6e-482e-a267-258f9e7ac117` | WAITING_FOR_BETA_REVIEW |

The three Beta App Review submissions were accepted into Apple's review queue. Existing developer contact and feedback-email details were reused from the previous app record; no contact data or credentials are stored here. Beta description and platform-specific What to Test notes were saved. Automatic tester notification is enabled for the builds.

Review notes disclose that Explore Sample Library supports interface inspection with simulated silent playback (Watch is browsing only). Real audio and downloads require a reachable Synology NAS and that NAS's account. No demo NAS credentials were invented or supplied; Apple can request additional review access through the existing contact details.

At initial submission on 20 September, the public invitation reported that the beta was not accepting new testers. This was the state before Apple's approval, not its current availability. The later approval and current release checks above supersede that wait; physical-device and NAS-provider acceptance remain in #123.

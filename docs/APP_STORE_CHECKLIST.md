# App Store readiness — Gumbo Music

Updated 21 September 2026 for App Store Connect app **6814252548**. The iOS, native Mac and TV 1.0 storefronts remain **Prepare for Submission**. TestFlight approval is separate from public App Store approval.

## Verified account and publication state

- App name: **Gumbo Music**.
- Age rating: **4+**, calculated and saved from the app’s actual features; API read-back confirms the answers. The app includes no supplied explicit media, public content feed, messaging, browser, advertising, gambling or age-assurance system. User-controlled private NAS media is not a curated Gumbo catalogue; profile locks are not represented as parental content filtering.
- Subtitle: **Your library. Your own space.**; primary category: **Music**. Both saved and independently read back on 21 September.
- Privacy policy URL: **https://gumbo.one/privacy/**. Apple TV inline policy was saved and read back against the published text.
- Support URL: **https://gumbo.one/support/**; marketing URL: **https://gumbo.one/**, saved and read back for all three platforms.
- en-GB descriptions and keywords are saved and read back for all three platforms. They describe the currently published Synology beta, not unverified vendor compatibility.
- Five native screenshots uploaded and processed **COMPLETE**, with dimensions and checksums independently verified: iPhone library/playlists (1320 × 2868), iPad library (2064 × 2752), native Mac library (2560 × 1600) and Apple TV library (3840 × 2160). They show the built-in fictional sample library; no private NAS library was uploaded. Capture notes distinguish isolated native Mac rendering from signed simulator captures.
- App Privacy answers were published with the owner’s explicit agreement and independently read back on 21 September. Apple reports and voluntary TestFlight feedback are disclosed for App Functionality, potentially linked to identity, with no tracking. See [the rationale and verification](PRIVACY-RELEASE-CHECK.md).
- CloudKit's optional `Family.providerConnection` Bytes field is now deployed and read back in Production; see [deployment evidence](CLOUDKIT-PROVIDER-DEPLOYMENT-2026-09-21.md).

## Build status

Public TestFlight build **1.0 (202609211143)** was verified as VALID / IN_BETA_TESTING across iOS, Mac and TV at 11:33 UTC on 21 September. It predates the provider implementation in PR #205. Source fixes and later local signed exports are not an uploaded replacement build.

The provider implementation adds dynamic libsmb2 and its standard SMB cryptographic code on iOS, Mac and TV. The old blanket `ITSAppUsesNonExemptEncryption=false` declaration is no longer applied to those targets. The owner confirmed France is included. The signed-in Apple questionnaire now has France selected and requires a French encryption declaration approval form; no document has been submitted. The unsigned preparation pack and official ANSSI route are tracked in [#208](https://github.com/svoltolini/gumbo/issues/208) and [the France release record](FRANCE-ENCRYPTION-RELEASE.md). Keep the declaration and review explicit before the next TestFlight upload; do not mark the binary exempt to skip the question. Watch does not link libsmb2. See [review notes](APP_REVIEW_NOTES.md) and [dependency decision](SMB-DEPENDENCY.md).

## Remaining public-release work

- [x] Complete, publish and verify app-level App Privacy answers against the code and owner-confirmed practices.
- [x] Upload and verify native iPhone, iPad, Mac and TV screenshots. Recheck them if the final submitted UI changes.
- [ ] Complete remaining applicable content-rights and review information. Age-rating answers are saved and verified.
- [ ] Resolve encryption documentation and distribution requirements for the provider binary; increment the build number for a new upload.
- [ ] Confirm public-review notes and provide authorized real-audio review access if required. The visible sample library supports UI review but contains no bundled audio; do not promise a demo server or invent credentials.
- [ ] Complete the physical NAS, iCloud, Watch, CarPlay and accessibility acceptance checks in #123.
- [ ] Verify pricing/availability and any owner-only agreements before public submission.

The user has authorized engineering, metadata preparation and TestFlight deployment. Request missing factual information only where it cannot be established from the code or account; do not treat every unchecked row as a new approval requirement.

## References

- [Current packaging evidence and reusable validation](APP-STORE-PACKAGING-VALIDATION.md)
- [Privacy inventory](PRIVACY-RELEASE-CHECK.md)
- [Public-store issue #119](https://github.com/svoltolini/gumbo/issues/119)
- [Physical acceptance issue #123](https://github.com/svoltolini/gumbo/issues/123)
- [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

Historical Skyr-era checklist results remain in the dated [release audit](RELEASE-AUDIT-2026-09-14.md) and [immutable evidence references](evidence/README.md); they are not current Gumbo acceptance evidence.

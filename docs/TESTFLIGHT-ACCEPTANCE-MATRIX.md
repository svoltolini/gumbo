# Gumbo 1.0 — TestFlight Acceptance Matrix

This document defines the acceptance testing required before Gumbo 1.0's public App Store release. The TestFlight beta is already available. It consolidates historical requirements from [#12](https://github.com/svoltolini/gumbo/issues/12) and the [release audit](RELEASE-AUDIT-2026-09-14.md); current physical/provider results belong in [#123](https://github.com/svoltolini/gumbo/issues/123).

**Current candidate**: 1.0 (**202609211143**), main `c6313140709805ac4361ed410aac5c0441bef063`. All iOS, native Mac and TV builds were **VALID / IN_BETA_TESTING** internally and externally at **11:33 UTC on 21 September 2026**. iOS includes Watch, widgets and CarPlay. Signed exports and 561 Release core tests passed; no physical acceptance row below is marked complete by those checks. See [current release evidence](https://github.com/svoltolini/gumbo/issues/123#issuecomment-5759326550) and [external-beta status](EXTERNAL-BETA-2026-09-20.md).

**Historical reference**: build 1.0 (202609151900) and audit baseline `73f85b74ab60a9707de2f744161b172d21ef5b4e` were used when this matrix was first prepared. They are not the current separate-identity TestFlight candidate. Identity/distribution work is recorded in [#118](https://github.com/svoltolini/gumbo/issues/118); public-store metadata/privacy remains in [#119](https://github.com/svoltolini/gumbo/issues/119).

## Testing Layers

| Layer | Scope | Runner |
| --- | --- | --- |
| Unit tests | Core logic, state management, persistence | `swift test` / CI |
| Preflight validation | Build settings, privacy manifests, signatures | `scripts/preflight-validation.sh` |
| Simulator smoke | UI rendering, basic flows | Xcode / CI |
| Device acceptance | Real hardware, NAS, network, accessories | Tester (manual) |
| Provider integration | DSM, CloudKit, Tailscale routes | Tester (manual) |

---

## Automated In-Repo Validation

These checks run without physical devices or TestFlight and are captured in `scripts/preflight-validation.sh`.

### Package Tests

Run the full GumboCore test suite:

```bash
cd Packages/GumboCore && swift test
```

Coverage areas:
- Profile authorization and persistence
- Download state, restoration, and reliability
- Catalogue caching and migration
- CloudKit sync reliability
- Family access and authorization
- Widget authorization
- Playback recovery
- Connection and transport validation

### Build Validation

Verify all targets compile for Release:

```bash
xcodebuild -project Gumbo.xcodeproj -scheme Gumbo -configuration Release -destination 'generic/platform=iOS' build
xcodebuild -project Gumbo.xcodeproj -scheme GumboMac -configuration Release -destination 'generic/platform=macOS' build
xcodebuild -project Gumbo.xcodeproj -scheme GumboTV -configuration Release -destination 'generic/platform=tvOS' build
```

### Version Alignment

All targets must share the same version numbers:

| Target | MARKETING_VERSION | CURRENT_PROJECT_VERSION |
| --- | --- | --- |
| Gumbo (iOS) | 1.0 | 202609211143 |
| GumboWidgets | 1.0 | 202609211143 |
| GumboWatch | 1.0 | 202609211143 |
| GumboMac | 1.0 | 202609211143 |
| GumboTV | 1.0 | 202609211143 |

### Privacy Manifest Validation

All five targets must include a PrivacyInfo.xcprivacy file with:
- `NSPrivacyTracking: false`
- `NSPrivacyCollectedDataTypes` declarations
- `NSPrivacyAccessedAPITypes` with reasons

Locations:
- `Gumbo/PrivacyInfo.xcprivacy`
- `GumboWidgets/PrivacyInfo.xcprivacy`
- `GumboWatch/PrivacyInfo.xcprivacy`
- `GumboMac/PrivacyInfo.xcprivacy`
- `GumboTV/PrivacyInfo.xcprivacy`

### Entitlements Check

Verify required capabilities in signed binaries:
- **iOS**: App Groups, CloudKit, CarPlay (approved), Push Notifications
- **Mac**: Sandbox, Network Client, CloudKit, Push Notifications
- **TV**: CloudKit, Push Notifications
- **Watch**: Companion app bundle identifier
- **iOS/Mac**: Matching personal Keychain access group for optional sign-in sync

### Export Compliance

Reassess the actual binary before each upload. Provider-aware iOS/Mac/TV builds include libsmb2 cryptography, so their former blanket `ITSAppUsesNonExemptEncryption=false` answer has been removed pending the encryption questionnaire and any required documentation. Watch uses Apple services and has no libsmb2 dependency. See [review notes](APP_REVIEW_NOTES.md).

---

## Device Acceptance Matrix

These tests **require physical devices and a real Synology NAS**. Record build number, device/OS version, DSM version, account type, and result for each row.

### iPhone and iPad

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Setup** | Fresh DSM connection (standard account) | | | | |
| | Fresh DSM connection (OTP 2FA account) | | | | |
| | Connection with Tailscale route | | | | |
| | Public HTTPS connection (if supported) | | | | |
| **Library** | Initial full scan | | | | |
| | Partial failure during scan | | | | |
| | Refresh after NAS content change | | | | |
| | Folder structure change handling | | | | |
| **Playback** | Local streaming | | | | |
| | Seeking within track | | | | |
| | Next-track transitions | | | | |
| | AirPlay to external speaker | | | | |
| **Downloads** | Offline download (single track) | | | | |
| | Offline download (album) | | | | |
| | Background transfer completion | | | | |
| | Offline playback verification | | | | |
| **Widgets** | Widget action launches app | | | | |
| | Now Playing widget updates | | | | |
| **Live Activity** | Activity appears and updates during a download | | | | |
| | Download completion/cancellation finishes the activity | | | | |
| | Activity deep link opens the current profile's download view | | | | |
| **Profiles** | Profile lock with PIN | | | | |
| | Profile switch | | | | |
| | Family owner invite | | | | |
| | Family member join | | | | |
| | Family member removal | | | | |
| **Interruptions** | Airplane mode during playback | | | | |
| | NAS restart recovery | | | | |
| | Session expiry and reauthentication | | | | |
| | App relaunch during download | | | | |
| | Account change (different Apple ID) | | | | |
| | Insufficient storage handling | | | | |
| | Incoming call during playback | | | | |
| | Headphone disconnect | | | | |
| **Shared-file maintenance** | Owner reviews exact album files and confirms deletion of a disposable fixture | | | | |
| | Member profile cannot initiate deletion; denied NAS permissions leave files intact | | | | |
| | Stop and interrupted replies report confirmed versus unconfirmed deletions | | | | |
| | Complete refresh removes deleted songs/downloads; partial refresh preserves valid copies | | | | |

### Mac (Native)

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Setup** | Fresh DSM connection | | | | |
| | Connection with OTP account | | | | |
| | Optional personal sign-in sync from iPhone; correct server/account/folder and OTP behavior | | | | |
| | Delayed Keychain arrival, changed password, opt-out and local sign-out | | | | |
| **Navigation** | Window resize handling | | | | |
| | Multiple window sizes | | | | |
| | Keyboard navigation | | | | |
| **Playback** | Local streaming | | | | |
| | Downloads and offline playback | | | | |
| **CloudKit** | Convergence with iOS device | | | | |
| | Profile sync after edit | | | | |
| | Simultaneous offline changes | | | | |
| **Accessibility** | VoiceOver navigation | | | | |
| | Full keyboard access | | | | |

### Apple TV

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Setup** | Fresh DSM connection | | | | |
| | Family Access connection reuse from iCloud (personal Keychain sync is unavailable on TV) | | | | |
| **Navigation** | Remote focus navigation | | | | |
| | Profile picker | | | | |
| **Playback** | Streaming playback | | | | |
| | Next/previous with remote | | | | |
| **Sync** | Family profile sync | | | | |
| | Profile updates from iOS | | | | |

### Apple Watch (Paired)

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Transfer** | Catalogue transfer from iPhone | | | | |
| | Nested-path download | | | | |
| **Download** | Download failure and retry | | | | |
| | Multiple track download | | | | |
| **Playback** | Offline independent playback | | | | |
| | Playback without iPhone | | | | |
| **Artwork** | Source covers, missing-cover fallback and refreshed covers in the native player | | | | |
| | Older catalogue delivery cannot revert newer artwork or deletion state | | | | |
| **Shared-file deletion** | Paired iPhone sync removes deleted songs/downloads, including after an offline interval | | | | |
| **Limitations** | Route limitation messaging | | | | |
| | OTP account limitation messaging | | | | |

### CarPlay

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Connection** | CarPlay session start | | | | |
| | Browse library via CarPlay | | | | |
| **Playback** | Start playback from CarPlay | | | | |
| | Playback controls | | | | |
| **UI** | Template rendering | | | | |
| | Now Playing screen | | | | |

---

## CloudKit Multi-Device Matrix

Personal sync checks require **two Apple devices signed into the same Apple Account** running the TestFlight build. Family owner/member checks additionally require controlled, distinct Apple Accounts. Record which configuration each result uses.

| Test Case | Device A | Device B | Result | Notes |
| --- | --- | --- | --- | --- |
| Profile created on A appears on B | | | | |
| Profile edit on A syncs to B | | | | |
| Simultaneous offline edits merge correctly | | | | |
| Profile deletion on A removes from B | | | | |
| Family member invite acceptance | | | | |
| Account change on A revokes its old-account access without erasing B's unrelated data | | | | |

---

## Accessibility Matrix

| Test Case | Platform | Result | Notes |
| --- | --- | --- | --- |
| Standard text size | iOS | | |
| Accessibility Extra Large text | iOS | | |
| VoiceOver navigation | iOS | | |
| VoiceOver navigation | Mac | | |
| Reduce Motion respected | iOS | | |
| Full keyboard access | Mac | | |
| Remote focus (no touch) | TV | | |
| Six profile limit UI | iOS | | |
| Long/Unicode profile names | iOS | | |

---

## Provider Configuration

### Required Synology DSM Setup

- DSM version: _______________
- Standard (non-2FA) test account: _______________
- OTP-enabled test account: _______________
- Least-privilege family test account: _______________
- Test library location: _______________
- Nested folder depth tested: _______________

### Network Routes Tested

| Route | Tested | Notes |
| --- | --- | --- |
| LAN (direct) | | |
| Tailscale (if offered) | | |
| Public HTTPS (if supported) | | |

---

## Sign-Off

All P1 device acceptance rows must pass before public App Store release. Attach diagnostics for failures and record only observed device/provider results; TestFlight availability and automated tests do not fill these rows.

| Sign-off | Name | Date | Build |
| --- | --- | --- | --- |
| iOS/iPad complete | | | |
| Mac complete | | | |
| Apple TV complete | | | |
| Apple Watch complete | | | |
| CarPlay complete | | | |
| CloudKit multi-device complete | | | |
| Accessibility complete | | | |

---

## References

- [Issue #123: Current physical/provider acceptance](https://github.com/svoltolini/gumbo/issues/123)
- [Issue #119: Public-store metadata and privacy](https://github.com/svoltolini/gumbo/issues/119)
- [Issue #12: Historical TestFlight acceptance matrix](https://github.com/svoltolini/gumbo/issues/12)
- [Release Audit](RELEASE-AUDIT-2026-09-14.md)
- [Remediation Batch 4](REMEDIATION-2026-09-14-BATCH-4.md)
- [Privacy Release Check](PRIVACY-RELEASE-CHECK.md)

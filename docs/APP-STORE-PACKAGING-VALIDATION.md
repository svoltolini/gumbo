# App Store Packaging Validation Checklist

Gumbo 1.0 — App Store distribution readiness

This checklist provides concrete validation steps for every App Store submission. It consolidates the acceptance criteria from [#13](https://github.com/svoltolini/gumbo/issues/13) and evidence from prior remediation batches.

## Quick Reference

The separate Gumbo identity is distributed through App Store Connect app **6814252548**. Signed exports for main `c6313140709805ac4361ed410aac5c0441bef063` were verified, and at **11:33 UTC on 21 September 2026** all three platform builds were **VALID / IN_BETA_TESTING** internally and externally. See [current release evidence](https://github.com/svoltolini/gumbo/issues/123#issuecomment-5759326550) and the [external-beta status](EXTERNAL-BETA-2026-09-20.md).

| Platform | Bundle ID | Build |
| --- | --- | --- |
| iOS (iPhone/iPad) | `com.samuelvoltolini.gumbo` | 1.0 (202609211143) |
| iOS Widgets | `com.samuelvoltolini.gumbo.widgets` | 1.0 (202609211143) |
| watchOS | `com.samuelvoltolini.gumbo.watchkitapp` | 1.0 (202609211143) |
| macOS | `com.samuelvoltolini.gumbo` | 1.0 (202609211143) |
| tvOS | `com.samuelvoltolini.gumbo` | 1.0 (202609211143) |

The unchecked items in sections 1–7 are a **reusable checklist for each future candidate**, not an assertion that the current build was never archived or uploaded. Build-specific results are recorded under Validation Evidence. Physical/provider acceptance remains in [#123](https://github.com/svoltolini/gumbo/issues/123), and public-store metadata/privacy remains in [#119](https://github.com/svoltolini/gumbo/issues/119).

---

## 1. Archive Build Validation

Run for each target before every TestFlight upload.

### 1.1 iOS Archive (includes Watch and Widgets)

```bash
xcodebuild archive \
  -project Gumbo.xcodeproj \
  -scheme Gumbo \
  -destination "generic/platform=iOS" \
  -archivePath build/Gumbo-iOS.xcarchive \
  -configuration Release
```

- [ ] Archive completes without error
- [ ] No unresolved asset catalog warnings
- [ ] Watch app embedded at `Products/Applications/Gumbo.app/Watch/Gumbo.app`
- [ ] Widgets extension embedded at `Products/Applications/Gumbo.app/PlugIns/GumboWidgets.appex`

### 1.2 macOS Archive

```bash
xcodebuild archive \
  -project Gumbo.xcodeproj \
  -scheme GumboMac \
  -destination "generic/platform=macOS" \
  -archivePath build/Gumbo-macOS.xcarchive \
  -configuration Release
```

- [ ] Archive completes without error
- [ ] Universal binary includes arm64 and x86_64

### 1.3 tvOS Archive

```bash
xcodebuild archive \
  -project Gumbo.xcodeproj \
  -scheme GumboTV \
  -destination "generic/platform=tvOS" \
  -archivePath build/Gumbo-tvOS.xcarchive \
  -configuration Release
```

- [ ] Archive completes without error
- [ ] Top Shelf assets present (1920×720, 2320×720 at required scales)
- [ ] Only expected notice: "Skipping AppIntents extraction" (expected)

---

## 2. App Store Export Validation

### 2.1 Export Archives

```bash
xcodebuild -exportArchive \
  -archivePath build/Gumbo-iOS.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore.plist \
  -exportPath build/export-ios
```

Repeat for macOS and tvOS archives.

- [ ] Export completes for all three platforms
- [ ] `.ipa` (iOS) or `.pkg` (macOS) generated
- [ ] No signing errors

### 2.2 Validate Exports

```bash
xcrun altool --validate-app -f build/export-ios/Gumbo.ipa \
  --type ios -u "$APPLE_ID" -p "$APP_SPECIFIC_PASSWORD"
```

- [ ] iOS validation passes: "No errors validating archive"
- [ ] macOS validation passes
- [ ] tvOS validation passes

---

## 3. Entitlements Verification

### 3.1 iOS Entitlements

Extract and verify from the signed `.app`:

```bash
codesign -d --entitlements - build/Gumbo-iOS.xcarchive/Products/Applications/Gumbo.app
```

**Required entitlements:**

| Entitlement | Value | Status |
| --- | --- | --- |
| `com.apple.developer.carplay-audio` | `true` | ✅ Approved |
| `com.apple.security.application-groups` | `group.com.samuelvoltolini.gumbo` | Required |
| `com.apple.developer.icloud-container-identifiers` | `iCloud.com.samuelvoltolini.gumbo` | Required |
| `com.apple.developer.icloud-services` | `CloudKit` | Required |
| `aps-environment` | `production` (Release) | Required |

- [ ] CarPlay audio entitlement present in binary
- [ ] CarPlay audio entitlement present in provisioning profile
- [ ] App Groups entitlement matches the widget extension
- [ ] Watch has its explicit Gumbo bundle identifier and matching distribution profile
- [ ] Personal Keychain access group matches between iOS and Mac
- [ ] CloudKit entitlements present

### 3.2 macOS Entitlements

```bash
codesign -d --entitlements - build/Gumbo-macOS.xcarchive/Products/Applications/Gumbo.app
```

- [ ] `com.apple.security.app-sandbox` is `true`
- [ ] `com.apple.security.network.client` is `true`
- [ ] CloudKit entitlements present

### 3.3 tvOS Entitlements

```bash
codesign -d --entitlements - build/Gumbo-tvOS.xcarchive/Products/Applications/Gumbo.app
```

- [ ] CloudKit entitlements present
- [ ] No unexpected entitlements

---

## 4. Privacy Manifest Validation

Each app/extension must include a valid `PrivacyInfo.xcprivacy`.

### 4.1 Manifest Locations

| Target | Path |
| --- | --- |
| iOS | `Gumbo/PrivacyInfo.xcprivacy` |
| Widgets | `GumboWidgets/PrivacyInfo.xcprivacy` |
| Watch | `GumboWatch/PrivacyInfo.xcprivacy` |
| Mac | `GumboMac/PrivacyInfo.xcprivacy` |
| TV | `GumboTV/PrivacyInfo.xcprivacy` |

### 4.2 Required Declarations

All manifests must declare:

```xml
<key>NSPrivacyTracking</key>
<false/>
<key>NSPrivacyCollectedDataTypes</key>
<array/>
<key>NSPrivacyAccessedAPITypes</key>
<array>
  <!-- UserDefaults and file timestamp reasons -->
</array>
```

- [ ] All five manifests present in archives
- [ ] `NSPrivacyTracking` is `false` in all manifests
- [ ] `NSPrivacyCollectedDataTypes` is empty array in all manifests
- [ ] Required-reason APIs documented with appropriate reasons

### 4.3 Verify in Archive

```bash
unzip -l build/export-ios/Gumbo.ipa | grep PrivacyInfo
```

- [ ] `Payload/Gumbo.app/PrivacyInfo.xcprivacy` present
- [ ] `Payload/Gumbo.app/Watch/Gumbo.app/PrivacyInfo.xcprivacy` present
- [ ] `Payload/Gumbo.app/PlugIns/GumboWidgets.appex/PrivacyInfo.xcprivacy` present

---

## 5. Asset Catalog Validation

### 5.1 iOS App Icons

- [ ] `AppIcon` iconset complete (all required sizes)
- [ ] No missing 1x/2x/3x variants warnings

### 5.2 Watch App Icons

- [ ] `WatchAppIcon` iconset complete
- [ ] Companion icon sizes included

### 5.3 TV Assets

- [ ] `TVIcon` complete with layered images
- [ ] Top Shelf images at required sizes:
  - `shelf-1920x720.png` (wide)
  - `shelf-2320x720.png` (wide, 4K)
- [ ] No "missing image" warnings in archive

### 5.4 Accent Colors

- [ ] `AccentColor` defined in asset catalog
- [ ] Renders correctly in Light and Dark modes

---

## 6. TestFlight Upload Validation

### 6.1 Upload Builds

```bash
xcrun altool --upload-app -f build/export-ios/Gumbo.ipa \
  --type ios -u "$APPLE_ID" -p "$APP_SPECIFIC_PASSWORD"
```

- [ ] iOS upload accepted
- [ ] macOS upload accepted  
- [ ] tvOS upload accepted

### 6.2 App Store Connect Processing

After upload, verify in App Store Connect:

- [ ] Build status: "Processing" → "Ready to Submit" (allow 15-60 minutes)
- [ ] Encryption questionnaire/documentation completed for the actual binary; no unresolved Missing Compliance status
- [ ] No "Invalid Binary" rejection email

### 6.3 TestFlight Internal Testing

- [ ] Build available in internal Testers group
- [ ] Testing notes saved and visible
- [ ] Build installs on test devices

**Current evidence:** All three Gumbo platform builds `202609211143` were `VALID / IN_BETA_TESTING` internally and externally at 11:33 UTC on 21 September 2026. The 14 September batch-4 result below belongs to the previous app identity and remains historical.

---

## 7. Version Management

### 7.1 Version Numbers

| Key | Value | Notes |
| --- | --- | --- |
| `MARKETING_VERSION` | `1.0` | Keep at 1.0 for public release |
| `CURRENT_PROJECT_VERSION` | Increment per upload | Format: `YYYYMMDDHHMM` |

### 7.2 Consistent Across Targets

All five targets must use identical version numbers:

```bash
grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" project.yml
```

- [ ] All targets show same `MARKETING_VERSION`
- [ ] All targets show same `CURRENT_PROJECT_VERSION`

### 7.3 Before Upload

- [ ] Increment `CURRENT_PROJECT_VERSION` in `project.yml`
- [ ] Regenerate Xcode project: `xcodegen generate`
- [ ] Verify build numbers match in Xcode

---

## 8. App Store metadata

The current account read-back is maintained in [APP_STORE_CHECKLIST.md](APP_STORE_CHECKLIST.md). On 21 September the Gumbo name, subtitle, Music category, three platform descriptions/keywords, privacy URL/TV policy text and support/marketing URLs were saved and verified. Five native iPhone, iPad, Mac and TV screenshots processed successfully with dimensions/checksums verified, and the 4+ age rating was saved and read back. All public storefronts remain **Prepare for Submission**.

Use Apple's [current screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/). The 6.9-inch iPhone and 13-inch iPad sets can supply scaled screenshots for smaller supported displays; do not require every old device size when Apple accepts scaling. Screenshots must be JPEG/PNG without transparency and reflect the submitted UI.

---

## 9. App Store Privacy Answers

App Store Connect requires app-level privacy declarations separate from privacy manifests.

The App Privacy declaration was published with explicit owner confirmation on 21 September. Reloading App Store Connect showed the published attribution and all eight categories. See `PRIVACY-RELEASE-CHECK.md` for the owner-confirmed diagnostics/feedback rationale. This is separate from app-version approval.

### 9.1 Data Types Declaration

Based on source review, Gumbo:
- Does not collect data for tracking
- Does not use third-party analytics SDKs
- Stores profile data in user's private CloudKit zone
- Does not transmit library data to developer servers

The owner confirmed use of Apple usage/crash reports to fix bugs and TestFlight-only feedback handling, then explicitly approved publication. Changes to those practices require an updated declaration.

### 9.2 Apple TV Privacy Text

tvOS requires inline privacy policy text in App Store Connect. Copy the essential policy text for display.

The new app's en-GB `privacyPolicyText` was null at the 21 September read-back.

- [ ] Privacy policy text entered in App Store Connect
- [ ] Text verified after save

---

## 10. App Review Preparation

### 10.1 Review Notes

The implemented review route is documented in [APP_REVIEW_NOTES.md](APP_REVIEW_NOTES.md). Keep store review notes consistent with:
- How to open **Explore Sample Library** from Welcome or the Watch's phone-sync screen
- NAS connection requirements
- Any special test account credentials

### 10.2 Demo Resources

| Option | Status |
| --- | --- |
| Explore Sample Library | Implemented on iPhone/iPad, Mac, TV and Watch; no developer launch arguments required |
| Sample playback | Simulated and silent on phone/Mac/TV; Watch sample supports browsing only |
| Real-audio review access | Requires a reachable Synology NAS and authorized credentials; no demo credentials were invented or supplied |
| Detailed review notes | Source updated; confirm public-review notes and any requested real-audio access before submission |

### 10.3 Contact Information

- [ ] Review contact email set
- [ ] Phone number for expedited review (optional)

---

## Validation Evidence

### Separate Gumbo identity — 21 September 2026

Build **1.0 (202609211143)**, main `c6313140709805ac4361ed410aac5c0441bef063`:

- Signed iOS/Watch/widgets, universal Mac and TV archives and App Store exports passed.
- All five exported bundles have matching versions, valid signatures and privacy manifests. Watch uses its explicit **Gumbo Watch App Store** profile.
- Production CloudKit, the Mac sandbox and both Mac architectures, matching personal Keychain groups on iOS/Mac, and the iOS CarPlay entitlement/profile/scene were verified.
- All **561 Release core tests across 36 suites** passed.
- App Store Connect reported all platform builds **VALID / IN_BETA_TESTING** internally and externally at **11:33 UTC**. The earlier Mac external-review wait has completed.
- Website and privacy-page HTTP 200 responses matched the merged source. Store privacy URL/TV text, support URLs and descriptions remained blank; app-level privacy answers were not independently verified.

These are packaging, automation and provider-state results. Physical NAS, iCloud, Watch and CarPlay journeys remain unchecked in [#123](https://github.com/svoltolini/gumbo/issues/123). The public App Store records remain `PREPARE_FOR_SUBMISSION`; TestFlight approval is not public App Store approval.

Evidence: [release record](https://github.com/svoltolini/gumbo/issues/123#issuecomment-5759326550), [identity record](GUMBO-IDENTITY.md), [external-beta status](EXTERNAL-BETA-2026-09-20.md).

### Historical validations (previous identity, batch 4, 14 September 2026)

The following results remain dated evidence for the previous app identity; they do not independently validate the new Gumbo identifiers.

| Check | Result | Build |
| --- | --- | --- |
| iOS Release archive | ✅ Passed | 1.0 (202609142150) |
| macOS Release archive | ✅ Passed | 1.0 (202609142150) |
| tvOS Release archive | ✅ Passed | 1.0 (202609142150) |
| App Store export (all platforms) | ✅ Passed | 1.0 (202609142150) |
| Privacy manifests (all 5) | ✅ Present | 1.0 (202609142150) |
| CarPlay entitlement (binary) | ✅ Approved | 1.0 (202609142150) |
| CarPlay entitlement (profile) | ✅ Approved | 1.0 (202609142150) |
| TestFlight upload (iOS) | ✅ VALID | 1.0 (202609142150) |
| TestFlight upload (macOS) | ✅ VALID | 1.0 (202609142150) |
| TestFlight upload (tvOS) | ✅ VALID | 1.0 (202609142150) |
| Internal TestFlight group | ✅ IN_BETA_TESTING | All platforms |

Evidence: [REMEDIATION-2026-09-14-BATCH-4.md](REMEDIATION-2026-09-14-BATCH-4.md), [PR #36](https://github.com/svoltolini/gumbo/pull/36)

### Remaining for Public Release

| Item | Owner | Blocker |
| --- | --- | --- |
| App Store privacy URL and Apple TV policy text | Owner | Yes; website policy is already live |
| Support URL | Owner | Yes |
| App Store descriptions | Owner | Yes |
| Screenshots (all platforms) | Owner | Yes |
| App-level privacy answers | Owner | Yes |
| Public-review notes and any required real-audio access | Owner | Yes; visible sample UI is already implemented |
| Physical/provider acceptance in #123 | Tester | Yes |

---

## Automation Notes

### Pre-Upload Checklist Script

```bash
#!/bin/bash
# Run before every TestFlight upload

echo "=== Gumbo Pre-Upload Validation ==="

# Check version consistency
echo "Checking version numbers..."
grep -E "CURRENT_PROJECT_VERSION:" project.yml | head -5

# Verify privacy manifests exist
echo "Checking privacy manifests..."
for manifest in Gumbo/PrivacyInfo.xcprivacy \
                GumboWidgets/PrivacyInfo.xcprivacy \
                GumboWatch/PrivacyInfo.xcprivacy \
                GumboMac/PrivacyInfo.xcprivacy \
                GumboTV/PrivacyInfo.xcprivacy; do
  if [ -f "$manifest" ]; then
    echo "✅ $manifest"
  else
    echo "❌ $manifest MISSING"
  fi
done

echo "=== Validation Complete ==="
```

### CI Integration

For automated validation in CI:

1. Build all Release archives
2. Run `xcrun altool --validate-app` on exports
3. Verify entitlements with `codesign -d --entitlements`
4. Check privacy manifest presence in archives

---

## References

- [Apple: Distribute your app](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Apple: App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Apple: Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files)
- [Apple: App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Issue #13: Packaging validation](https://github.com/svoltolini/gumbo/issues/13)
- [Batch 4 evidence](REMEDIATION-2026-09-14-BATCH-4.md)

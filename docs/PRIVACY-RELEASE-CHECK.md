# Privacy release evidence

This is an engineering inventory and publication record. The current Gumbo declaration was published on 21 September 2026; see the final section for owner-confirmed practices and read-back evidence. Earlier sections retain their dated context.

## Website policy source — 21 September 2026

[`website/privacy/index.html`](../website/privacy/index.html) is the publication source for [gumbo.one/privacy/](https://gumbo.one/privacy/), covering the app and website. Production availability must be checked after deployment. The policy uses TestFlight's feedback/developer-contact route during the beta; an approved public support email and the developer's support-retention practices remain operational follow-up. This website work does not update App Store Connect privacy fields, tvOS policy text or app-level privacy answers.

## Previously verified store state (batch 4)

This section records the previous app identity. It was not refreshed during the September 20 remediation and does not establish the current Gumbo App Store record or published privacy state. New-identity verification is tracked in [#119](https://github.com/svoltolini/gumbo/issues/119).

App Store Connect API: app `6811461121`, app info `67902bd2-bf96-476e-b090-3b91431c1962`, en-GB localization `4f44c0ad-b6c9-47e9-85cb-cae23e2c7bb2`. `privacyPolicyUrl`, `privacyChoicesUrl` and `privacyPolicyText` were all null. At that time, the owner confirmed there was no public website or support contact. The API record was a preparation-for-submission record; that batch did not submit a public release.

## Data flow inventory

| Feature | Data and destination | Source evidence |
| --- | --- | --- |
| NAS sign-in and playback | Credentials, folder/media requests to the configured NAS; catalogue/downloads stored on device | `Networking/SynologyClient.swift`, `State/AppModel.swift`, `State/LibraryStore.swift`, `State/DownloadManager.swift` |
| Optional genre lookup | User-started album and artist text queries, plus the device's country/region setting, to Apple music search; no audio, NAS paths or credentials; review before NAS tag writes | `Networking/GenreLookup.swift`, `LibraryMaintenanceView.swift` |
| Shared-file maintenance | Owner-controlled reviewed genre edits and confirmed damaged-file deletion on the connected NAS; no Gumbo service receives files | `MetadataWriter.swift`, `MusicFileInspection.swift` |
| Album artwork | NAS-folder images and embedded music pictures only; no external artwork search or image requests | `Indexing/CoverStore.swift`, source reads in `LibraryIndexer.swift` and `LibraryStore.swift`, `GumboShared/ArtworkPolicy.swift` |
| Profile sync | Name, chosen photo, role, dates, Apple user-record association, PIN verification values; favourites, playlists, searches, recent plays and settings in private/family-shared CloudKit zone | `CloudSync.record(for:)`, `Models/Profile.swift`, `ProfileStateMerge.swift` |
| Family connection | NAS address, names, account and music folder in family CloudKit record; selected Family Access password in `record.encryptedValues`; anyone with the share link can join | `CloudSync.record(for: FamilyInfo)` |
| Watch and widgets | Watch playlist metadata, bounded source-library cover thumbnails, mosaic colour pairs, and the connection information needed for NAS downloads. Thumbnails are generated locally, stripped of source image metadata and sent only to the paired Watch. Widgets receive cover copies and metadata in an app-group snapshot. | `GumboWatch/WatchStore.swift`, `WatchDownloads.swift`, `Models/WatchCatalogue.swift`, `Models/WatchArtwork.swift`, `WidgetFeed.swift`, `GumboShared/WidgetSnapshot.swift` |
| Diagnostics | Local diagnostic file, potentially included in device backups, copied on user action; no automatic upload by Gumbo | `DiagnosticsLog.swift`, `DiagnosticsView.swift` |
| TestFlight | Apple provides beta usage/crash information, including sessions, installation information and build version. Public-link enrolment does not itself expose name/email; submitted feedback can include contact information, comments, screenshots and diagnostics | [TestFlight & Privacy](https://www.apple.com/legal/privacy/data/en/test-flight/), [public invitation and feedback guidance](https://testflight.apple.com/join/GensWMTh) |
| Website | Static content with no analytics scripts, sign-up form, or cookies/browser storage set by site code; Vercel processes hosting/security requests, separately from the NAS library | `website/index.html`, `website/site.js`, `website/vercel.json`, `website/privacy/index.html` |
| Biometrics | Operating-system authentication result; no biometric template exposed to Gumbo | `ProfileStore.swift` |

The packages include GumboCore, GumboShared and the dynamic GumboSMB transport library. GumboSMB provides SMB networking and cryptography, not analytics or a developer-operated collection service. The project targets include privacy manifests declaring required UserDefaults/file-timestamp reasons, no tracking, and no developer-collected data types. These manifests are not substitutes for the app-level App Store answers.

## Proposed App Store answer rationale to confirm before publication

Apple distinguishes data transmitted for real-time processing from data retained for later access. Its guidance also distinguishes information the developer receives from Apple services from information collected by Apple itself. Optional behavior does not automatically qualify for optional disclosure. See [Apple's data collection and Apple-service guidance](https://developer.apple.com/app-store/app-privacy-details/).

For the app code reviewed here, no developer-operated backend receives user library data, no analytics SDK is present, and no cross-app advertising tracking is implemented. CloudKit data lives in the user's private/family-shared zone. NAS and iCloud requests still occur for their respective features; do not describe the app as sending nothing outside the local network.

The owner must confirm any developer access/use outside this code, particularly App Store analytics, TestFlight reports and voluntarily submitted support information, before publishing an app-level "Data Not Collected" answer. If retained developer-accessible data is used, classify its actual type, purpose and linkage under Apple's definitions instead. Do not invent a location or tracking use solely because a server sees an IP address.

The no-tracking manifest declaration is consistent with the reviewed source. The collected-data declaration needs to be reconciled with the final owner-confirmed practices, rather than being changed speculatively to a fabricated collection category.

## Remaining publication work

1. Verify the deployed policy at `https://gumbo.one/privacy/`. Confirm an approved public support email and support-retention practice beyond the current TestFlight contact route.
2. Set that public URL and Apple TV policy text, then verify read-back through App Store Connect. The website change does not perform these store updates.
3. App-level answers were saved, published with owner confirmation, and read back on 21 September 2026. Reconcile them again if the release changes data handling.
4. Confirm onboarding and Settings behavior on the signed TestFlight builds across platforms.

Apple requires a public privacy-policy URL and tvOS policy text before public release: [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).

## Related documentation

- [App Store Packaging Validation](APP-STORE-PACKAGING-VALIDATION.md) — Complete checklist for archive builds, entitlements, privacy manifests, TestFlight uploads, and App Store metadata requirements.

## Current Gumbo declaration preparation — 21 September 2026

The owner confirmed: Apple usage/crash reports are used to fix bugs; feedback stays in TestFlight. The current app is `6814252548`. Privacy URL, tvOS policy and support URLs have been saved and independently read back.

The published App Privacy declaration contains eight categories: Name, Email Address, Photos or Videos, Customer Support, Product Interaction, Crash Data, Performance Data and Other Diagnostic Data. Each is used for App Functionality, potentially linked to identity, and not used for tracking. This covers developer-accessible Apple reports and voluntarily supplied TestFlight feedback/contact details/screenshots; it does not claim that Gumbo uploads private music or CloudKit profile libraries to a developer backend. Optional feedback is disclosed rather than assuming every submission qualifies for Apple's optional-disclosure exception. Apple can associate beta reports with invited testers or submitted contact details, so the declaration does not promise universal anonymization.

The owner explicitly approved Apple’s final accuracy/compliance/update statement. The declaration was then published and the page reloaded: **Published a few seconds ago by Sam Voltolini**, with all eight data types still present, each used for App Functionality and linked to identity. No category is used for tracking. This publishes privacy responses, not an App Store version or new TestFlight build.

# Gumbo identity and distribution

The 20 September 2026 rename creates a **separate app identity**, as explicitly selected by the owner. The previous TestFlight app and its local/CloudKit data remain independent. This change does not migrate installations, credentials, profiles, downloads, family invitations or widgets from that app.

## Source and build names

- Project: `Gumbo.xcodeproj`, generated from `project.yml`.
- Application targets: `Gumbo`, `GumboMac`, `GumboTV`, `GumboWatch`.
- Extension target: `GumboWidgets`.
- Package/products: `Packages/GumboCore`, `GumboCore`, `GumboShared`.
- Tests: `GumboCoreTests`.
- URL scheme: `gumbo`.

## Identity values

| Resource | Identifier |
| --- | --- |
| iPhone/iPad, Mac and TV application | `com.samuelvoltolini.gumbo` |
| Widget extension | `com.samuelvoltolini.gumbo.widgets` |
| Watch companion | `com.samuelvoltolini.gumbo.watchkitapp` |
| CloudKit container | `iCloud.com.samuelvoltolini.gumbo` |
| App group | `group.com.samuelvoltolini.gumbo` |
| Keychain service | `com.samuelvoltolini.gumbo.server` |
| Background indexing | `com.samuelvoltolini.gumbo.index` |
| Background audio downloads | `com.samuelvoltolini.gumbo.downloads` |
| Watch background downloads | `com.samuelvoltolini.gumbo.watch.downloads` |

Local catalogue, profile, cloud, cover and download paths use `Gumbo/` under the appropriate app support/cache directory. New widget kinds, profile-document format markers and temporary file names also use Gumbo. Source files and build commands consistently use the new names.

## Verified identity and distribution — 21 September 2026

The separate Gumbo identity is registered and distributed through TestFlight. Build **1.0 (202609211143)** comes from main `c6313140709805ac4361ed410aac5c0441bef063` (PR #187). At **11:33 UTC on 21 September 2026**, App Store Connect reported all three platform builds **VALID / IN_BETA_TESTING** for both internal and external testing. Mac's earlier external-review wait has ended.

- [x] Register explicit app, widget and Watch identifiers, the app group and CloudKit container.
- [x] Configure the required capabilities and distribution profiles for iOS, widgets, Watch, Mac and TV. Watch uses the explicit **Gumbo Watch App Store** profile.
- [x] Verify CarPlay Audio in the exported iOS app and distribution profile, together with its scene registration.
- [x] Create App Store Connect app **Gumbo Music**, Apple ID **6814252548**, and configure the TestFlight platform records, testing notes and groups.
- [x] Deploy the new CloudKit production schema, including the photo, PIN and encrypted Family Access fields; this was verified on 20 September 2026.
- [x] Verify signatures, matching versions and privacy manifests in all five distributed bundles, production CloudKit entitlements, the Mac sandbox/universal binary and matching personal Keychain groups on iOS/Mac.
- [x] Record uploads and distribution results in GitHub. See [#123 release evidence](https://github.com/svoltolini/gumbo/issues/123#issuecomment-5759326550) and the [current external-beta record](EXTERNAL-BETA-2026-09-20.md).

The identity work is tracked in [#118](https://github.com/svoltolini/gumbo/issues/118). The following distinct release gates remain open:

- [ ] Complete physical NAS, CloudKit owner/member, phone, Mac, TV, Watch, widget and CarPlay journeys in [#123](https://github.com/svoltolini/gumbo/issues/123).
- [ ] Complete public App Store privacy/support metadata and app-level privacy answers in [#119](https://github.com/svoltolini/gumbo/issues/119). The public website policy is live, but the store privacy URL, TV text and support URLs were still blank at the 21 September read-back.

TestFlight availability and schema/signature checks do not establish those runtime journeys or public App Store submission.

## Historical development signing — 20 September 2026

Before distribution, Xcode registered the Gumbo resources and a signed Release iPhone build succeeded with version `1.0` / build `202609151900`, including Watch and widgets. Its app profile contained the new CloudKit, app-group and CarPlay entitlements; **at that earlier stage** the Watch development profile was a wildcard profile. This was development-signing evidence only. The explicit Watch distribution profile and later TestFlight release above supersede that provisioning state without turning the earlier build into distribution or runtime acceptance evidence.

Both Debug and Release retain the required app capabilities; no reduced-capability development configuration is used.

## Historical records

Earlier remediation/release documents are historical; product and source-path spelling has been normalized for navigation in the current tree. Their dates, measurements and results do not validate the new app identity.

The files under `docs/evidence/` are immutable-source references to the original pre-rename evidence, including content hashes. This preserves the original signed bundle identifiers, measured symbols and paths without relabeling old observations as Gumbo verification. New validation should record fresh results and the exact revision/build in GitHub.

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

## Distribution gate

Source configuration and unsigned/simulator builds cannot register or verify Apple services. Before distributing this identity:

- [ ] Register the new explicit app/extension identifiers, app group and CloudKit container under the development team.
- [ ] Enable the required capabilities and obtain provisioning profiles for each platform.
- [ ] Obtain/verify the managed CarPlay entitlement for the new app identifier. Approval for an earlier identifier is not evidence for this one.
- [ ] Configure the new App Store Connect identity and required platform metadata.
- [ ] Prepare and deploy the new CloudKit production schema; validate owner/member sharing using controlled accounts.
- [ ] Run signed-device acceptance for phone, Mac, TV, Watch, widgets, downloads and family invitations.
- [ ] Record the exact build and upload outcome in GitHub before calling the new identity available in TestFlight.

These gates remain tracked in [#118](https://github.com/svoltolini/gumbo/issues/118). No registration, schema deployment, App Store submission or TestFlight upload is implied by the rename.

## Historical records

Earlier remediation/release documents are historical; product and source-path spelling has been normalized for navigation in the current tree. Their dates, measurements and results do not validate the new app identity.

The files under `docs/evidence/` are immutable-source references to the original pre-rename evidence, including content hashes. This preserves the original signed bundle identifiers, measured symbols and paths without relabeling old observations as Gumbo verification. New validation should record fresh results and the exact revision/build in GitHub.

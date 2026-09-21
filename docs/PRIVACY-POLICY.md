# Gumbo Music privacy policy — source reference

The public policy is maintained in [`website/privacy/index.html`](../website/privacy/index.html), with canonical URL [gumbo.one/privacy/](https://gumbo.one/privacy/). This document retains the app data-flow reference and release follow-up. Verify the live page after deployment; adding its source does not update App Store Connect privacy fields or app-level answers. The in-app Privacy Details page remains available offline.

## Your music and NAS

Gumbo Music connects to the NAS you select to read your music files, tags and cover images. Music streams directly from that NAS or plays from downloads on your device. Gumbo does not operate a music-storage service and does not upload your music files to a Gumbo server.

Your NAS receives the credentials, folder requests and media requests needed for these features. Its administrator controls its permissions, logging and retention. If you choose Remember Me, your personal NAS password is saved in the device Keychain. NAS addresses, account names, selected folders and library metadata are saved locally so Gumbo can reconnect and display the library.

## Optional sign-in sync

On iPhone, iPad and Mac, **Sync sign-in with iCloud Keychain** is optional and off by default. When enabled, the saved NAS address, account and password sync through Apple's iCloud Keychain to Gumbo on devices using the same Apple Account with Passwords & Keychain enabled. This does not add personal credentials to the family CloudKit record or share them with Gumbo family members. Two-factor codes and NAS sessions are not synced this way. Apple TV does not use this sign-in sync.

Turn it off in Settings → Music Server to remove the synced copy. Local passwords already remembered by individual devices remain; signing out of one device removes its local sign-in without removing the synced copy. iCloud Keychain changes require connectivity and Apple's sync service to reach other devices.

## Album artwork

Gumbo uses cover images from your NAS folders and pictures embedded in your music files. It does not send artist or album names to an online artwork search service. If your files have no cover, Gumbo shows a generated design.

## Optional genre lookup and file maintenance

When you choose Find Suggestions in Advanced Settings, Gumbo sends album and artist names, together with the device's country or region setting, to Apple's music catalogue to look for matching genres. This lookup is optional and happens only after you start it. It does not send audio, file paths or NAS credentials. You can enter a genre yourself without using online lookup. Suggestions are reviewed before saving, and existing genre tags are preserved.

Saving reviewed genres writes tags to the original files on your NAS, affecting everyone who uses those files. The owner can use Problem Files to check songs with missing playback information and permanently delete selected damaged files after reviewing the results and confirming. Removing a download only removes a device copy; deleting from Problem Files removes a shared original. Copies on other devices and server backups may remain.

## iCloud and family sharing

When iCloud is available, Gumbo uses Apple's CloudKit service to synchronize profile names, selected profile photos, favourites, playlists, recent plays, recent searches, settings and change-reconciliation information. Profile records also include the profile's Apple account association, role, dates, and PIN verification values when a PIN is set. This is data in the app's private or family-shared CloudKit zone, not a Gumbo-operated database.

Anyone with a family invitation link can join that family and receive its shared profiles and server details. Shared server details include the server address and name, account name and music folder. Gumbo shares the NAS credentials selected in Family Access, with the password in an encrypted CloudKit field so members can connect. Gumbo does not automatically share the owner's personal NAS password, but an account explicitly selected for Family Access is shared. Use a separate read-only NAS account for this purpose. Profile PINs and biometric unlock control the app interface; they do not change the sharing permissions of the CloudKit zone or the NAS.

## Local copies and connected devices

Gumbo keeps its catalogue, covers, preferences and downloaded music on your devices. Removing a download removes the device's copy, not the original NAS file. Apple TV can purge cache storage. Device backups and NAS backups may retain copies according to your settings and the provider's behavior.

The paired Watch can receive playlist metadata, colours for playlist mosaics, and the current NAS address, account and password from the iPhone, then download music from the NAS. The password is saved in the Watch Keychain. Gumbo does not send cover image files to the Watch. Widgets and Apple playback surfaces, including Now Playing, AirPlay and CarPlay, receive the metadata or audio needed for the features you use. Face ID and Touch ID are handled by the operating system; Gumbo receives the authentication result, not biometric templates.

## Diagnostics, distribution and support

Gumbo contains no advertising SDK, third-party analytics SDK or automatic upload of its local diagnostic log. The log can contain profile names, server details and errors; Gumbo does not automatically send it to the developer, but it may be included in device backups or shared if you copy it. You can clear it from Diagnostics.

Apple provides App Store and TestFlight distribution under its own terms and your Apple settings. TestFlight shares beta usage and crash information with the developer, including sessions, installation information and the installed build. Joining through the public link does not by itself show the developer your name or email. Submitted feedback can include comments, screenshots, contact information and diagnostics, and is received by Apple and the developer. See [TestFlight & Privacy](https://www.apple.com/legal/privacy/data/en/test-flight/).

During the beta, testers can use Send Beta Feedback on iPhone, iPad or Mac, or find the developer's email in TestFlight's Information/App Details section. Information sent for support is used to investigate problems, improve the beta and respond to requests. An approved public support email and the developer's support-retention practices remain operational follow-up; do not invent a retention deadline or publish private App Store review contacts.

## Website

The public policy also covers gumbo.one: a static site hosted by Vercel, with no sign-up form, advertising pixels, analytics scripts, cookies or browser storage set by its own code. Hosting and security involve ordinary web-request information, separately from the music library. Following a beta link opens Apple's TestFlight service; the website does not collect NAS credentials or enrol testers itself. See the publication source for the current website disclosure and provider links.

## Your choices

You can remove downloads, edit or delete eligible profiles, and clear diagnostics in Gumbo. iCloud changes and deletions need connectivity to reach other devices. Family access can be managed in Gumbo and on the NAS; removing a participant does not recall copies already downloaded on that person's devices. You can also manage Apple service and backup settings through Apple. Shared-file maintenance requires the library owner and NAS write permissions. Gumbo cannot remove independent NAS logs, NAS backups or copies on other devices through these controls.

## Remaining release checks

- Confirm an approved public support email and how voluntarily submitted support material is retained; the beta currently uses the TestFlight contact route.
- Verify the deployed policy at `https://gumbo.one/privacy/`, then set that URL and Apple TV policy text in App Store Connect and verify read-back. These store changes are not performed by the website update.
- Complete the app-level privacy answers consistently with the release's behavior and Apple's definitions; document the reasoning in `PRIVACY-RELEASE-CHECK.md`.

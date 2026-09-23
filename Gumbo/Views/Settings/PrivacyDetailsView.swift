import SwiftUI

/// Available offline, including before a person connects their library.
struct PrivacyDetailsView: View {
    static let artworkDisclosure = "Gumbo uses cover images from your NAS folders and pictures embedded in your music files. It does not send artist or album names to an online artwork search service. If no picture is available, Gumbo shows a generated design."

    private let sections: [(title: String, paragraphs: [String])] = [
        ("Your music", [
            "Gumbo reads music, tags and covers from the NAS you connect. Music streams directly from your NAS or plays from downloads on your device. Gumbo does not upload your music files to a Gumbo service.",
            "Your NAS receives the sign-in details and file requests needed to connect and play music. Its administrator controls the server and its logs. If you choose Remember Me, Gumbo saves your personal NAS password in the device Keychain."
        ]),
        ("Album artwork", [
            Self.artworkDisclosure
        ]),
        ("Optional genre lookup and file maintenance", [
            "When you choose Find Suggestions in Advanced Settings, Gumbo sends album and artist names to Apple's music catalogue to look for genres. It does not send audio, file paths or NAS sign-in details. You can enter genres yourself without using online lookup.",
            "Saving album, album artist or genre changes edits the original NAS music files. With Synology's built-in editing path, Gumbo downloads each selected file to your device and uploads the rewritten file to your NAS. WebDAV and SMB connections cannot edit tags unless you enable the separate helper. SMB connections can delete reviewed files directly when the NAS allows it; WebDAV connections need the helper for deletion.",
            "On supported connections, the library owner can permanently delete an album or selected, rechecked damaged files after reviewing and confirming the original files. Tag edits and original-file deletion affect everyone using that NAS; they are different from removing a download from your device."
        ]),
        ("Optional metadata helper", [
            "The library owner can enable a separate helper installed by you or your NAS administrator. Gumbo sends relative file paths, requested album, album artist or genre changes, file fingerprints and job identifiers to the HTTPS address you choose. It does not upload audio or send your NAS password to that address. The helper reads and edits the music files through its own mounted folder.",
            "The helper's operator controls its access to those files, job records and logs. Its separate access token is saved in this device's Keychain; it is not included in personal sign-in sync or family CloudKit records. The helper is not run by Gumbo, is not needed for listening, and deletes files only when both the helper and the library owner allow reviewed deletion."
        ]),
        ("Your sign-in across devices", [
            "On iPhone, iPad and Mac, Sync sign-in with iCloud Keychain is optional and off by default. When enabled, your saved NAS address, account and password sync through Apple’s iCloud Keychain to Gumbo on devices using the same Apple Account with Passwords & Keychain enabled. It does not share your password with your Gumbo family or save it in family CloudKit records.",
            "You can turn this off in Settings → Music Server. This removes the synced copy while keeping sign-ins already remembered on individual devices. Signing out of one device removes its local sign-in, but does not remove the synced copy. Two-factor codes and NAS sessions are not synced this way. Apple TV does not use this sign-in sync."
        ]),
        ("iCloud and family sharing", [
            "When iCloud is available, Gumbo syncs profile names, chosen profile photos, favourites, playlists, recent plays, searches and settings through Apple's CloudKit service. It also syncs the information needed to reconcile your changes between devices.",
            "People with your family invitation link can join and receive shared profiles and server details. Gumbo shares the NAS credentials you choose for Family Access, with the password in an encrypted CloudKit field. Use a separate read-only NAS account for your family.",
            "A profile PIN or biometric unlock controls access inside Gumbo. Family sharing and the permissions on your NAS determine who can receive the shared library information."
        ]),
        ("Your devices", [
            "Gumbo stores its catalogue, preferences, covers and downloads on your devices. Downloads are copies: removing them in Gumbo does not delete the original music on your NAS. Apple TV may clear cached data to recover space.",
            "Widgets, Now Playing, AirPlay and CarPlay use the information needed to show and control playback.",
            "Face ID and Touch ID are handled by the operating system. Gumbo receives an authentication result, not your biometric data."
        ]),
        ("Apple Watch", [
            "Your paired Watch can receive playlist metadata, small cover thumbnails and colours for playlist mosaics from your iPhone. For Synology and HTTPS WebDAV connections, it can also receive the server address, account and password to download music directly. The password is saved in the Watch Keychain.",
            "For SMB shared folders, Gumbo prepares songs on a reachable iPhone with the app open, then sends the audio files to your Watch through Apple's WatchConnectivity for local playback. The Watch does not connect directly to SMB or receive the SMB account or password. Transfer timing is controlled by the operating system.",
            "These transfers are between your devices; audio and cover thumbnails are not uploaded to a Gumbo service. A disconnected Watch may keep existing downloads until it reconnects and receives library or access changes."
        ]),
        ("Diagnostics and choices", [
            "Gumbo includes no advertising or third-party analytics SDK. Gumbo does not automatically send its diagnostic log to the developer. It may be included in device backups or shared if you copy it. The log can contain profile names, server details and error information. You can clear it from Diagnostics.",
            "Apple handles App Store and TestFlight services under its own privacy terms and your Apple settings. TestFlight feedback or crash reports that you share through Apple may be available to the developer.",
            "You can remove downloads, edit or delete eligible profiles, and clear local diagnostics in Gumbo. Synced edits and deletions require a working iCloud connection. Copies already downloaded by another family device, and backups managed by Apple or your NAS, have their own retention."
        ])
    ]

    var body: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectableText()
                            #if os(tvOS)
                            .focusable()
                            #endif
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle("Privacy Details")
        .inlineTitle()
    }
}

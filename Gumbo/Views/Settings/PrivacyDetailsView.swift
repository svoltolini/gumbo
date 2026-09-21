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
            "Saving reviewed genres writes tags into the original NAS music files. The library owner can permanently delete an album or selected, rechecked damaged files after reviewing and confirming the original files. These changes affect everyone using that NAS; they are different from removing a download from your device."
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
            "The paired Watch can receive playlist metadata, small cover thumbnails from your library, colours for playlist mosaics, and your current NAS address, account and password from your iPhone, then download music from the NAS. The password is saved in the Watch Keychain. Cover thumbnails stay on your devices and are used by the Watch player; they are not uploaded to a Gumbo service. Widgets, Now Playing, AirPlay and CarPlay use the information needed to show and control playback.",
            "Face ID and Touch ID are handled by the operating system. Gumbo receives an authentication result, not your biometric data."
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

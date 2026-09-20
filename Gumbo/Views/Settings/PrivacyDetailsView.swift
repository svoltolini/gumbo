import SwiftUI

/// Available offline, including before a person connects their library.
struct PrivacyDetailsView: View {
    static let artworkDisclosure = "Gumbo uses cover images from your NAS folders and pictures embedded in your music files. It does not send artist or album names to an online artwork search service. If no picture is available, Gumbo shows a generated design."

    private let sections: [(title: String, paragraphs: [String])] = [
        ("Your music", [
            "Gumbo reads music, tags and covers from the NAS you connect. Music streams directly from your NAS or plays from downloads on your device. Gumbo does not upload your music files to a Gumbo service.",
            "Your NAS receives the sign-in details and file requests needed to connect and play music. Its administrator controls the server and its logs. Gumbo saves your personal NAS password in the device Keychain."
        ]),
        ("Album artwork", [
            Self.artworkDisclosure
        ]),
        ("iCloud and family sharing", [
            "When iCloud is available, Gumbo syncs profile names, chosen profile photos, favourites, playlists, recent plays, searches and settings through Apple's CloudKit service. It also syncs the information needed to reconcile your changes between devices.",
            "People with your family invitation link can join and receive shared profiles and server details. Gumbo shares the NAS credentials you choose for Family Access, with the password in an encrypted CloudKit field. Use a separate read-only NAS account for your family.",
            "A profile PIN or biometric unlock controls access inside Gumbo. Family sharing and the permissions on your NAS determine who can receive the shared library information."
        ]),
        ("Your devices", [
            "Gumbo stores its catalogue, preferences, covers and downloads on your devices. Downloads are copies: removing them in Gumbo does not delete the original music on your NAS. Apple TV may clear cached data to recover space.",
            "The paired Watch can receive playlist metadata, colours for playlist mosaics, and your current NAS address, account and password from your iPhone, then download music from the NAS. The password is saved in the Watch Keychain. Gumbo does not send cover image files to the Watch. Widgets, Now Playing, AirPlay and CarPlay use the information needed to show and control playback.",
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

import GumboCore
import SwiftUI

struct SettingsTabView: View {
    @Namespace private var artworkNamespace

    var body: some View {
        NavigationStack {
            SettingsView().libraryDestinations()
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }
}

/// The same destinations appear as a native sidebar in the Mac Settings window.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "Appearance"
    case library = "Music Library"
    case server = "Music Server"
    case profiles = "Profiles & Family"
    case privacy = "Privacy"
    case advanced = "Advanced Settings"
    case about = "About"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "circle.lefthalf.filled"
        case .library: "music.note.list"
        case .server: "externaldrive"
        case .profiles: "person.2"
        case .privacy: "hand.raised"
        case .advanced: "gearshape.2"
        case .about: "info.circle"
        }
    }
}

/// A short overview leads to focused native forms. Maintenance tools live in Advanced Settings.
struct SettingsView: View {
    var category: SettingsCategory? = nil
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProfileStore.self) private var profiles
    @Environment(CloudSync.self) private var cloud
    @State private var isConfirmingSignOut = false
    @State private var isRecoveringLegacyLibrary = false
    @State private var isConfirmingTagRead = false
    @State private var isShowingRemoteAccessHelp = false

    private var permissions: Permissions { Permissions(profiles: profiles, cloud: cloud) }
    private var canScan: Bool { model.isConnected && !model.isScanning && !model.isDemo }

    var body: some View {
        Form {
            switch category {
            case nil: overview
            case .general: appearanceSection
            case .library: librarySections
            case .server:
                serverSections
                if permissions.canLeave { signOutSection }
            case .profiles: profileSections
            case .privacy:
                Section {
                    NavigationLink { PrivacyDetailsView() } label: {
                        NativeSettingsLabel("Privacy Details", symbol: "hand.raised")
                    }
                } footer: { Text(PrivacyDetailsView.artworkDisclosure) }
            case .advanced: advancedSections
            case .about: aboutSections
            }
        }
        .groupedForm()
        .navigationTitle(category?.rawValue ?? "Settings")
        .titleDisplay(large: category == nil)
        .sheet(isPresented: $isRecoveringLegacyLibrary) { LegacyLibraryRecoverySheet() }
        #if os(tvOS)
        .fullScreenCover(isPresented: $isShowingRemoteAccessHelp) { RemoteAccessGuide() }
        #else
        .sheet(isPresented: $isShowingRemoteAccessHelp) { RemoteAccessGuide() }
        #endif
        .confirmationDialog("Refresh song information?", isPresented: $isConfirmingTagRead, titleVisibility: .visible) {
            Button("Refresh Song Information") { model.rereadMetadata() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Gumbo will read album and song information from your music files again. This may take a while. Your favourites and playlists stay in place.")
        }
        .confirmationDialog(library.isDemo ? "Leave the sample library?" : "Sign out of your music server?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button(library.isDemo ? "Leave Sample Library" : "Sign Out", role: .destructive) {
                player.pause()
                Task { await model.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved connection and cached library will be removed from this device. Music files on your server stay in place.")
        }
    }

    private var overview: some View {
        Group {
            Section {
                NavigationLink { SettingsView(category: .profiles) } label: { profileLabel }
                NavigationLink { FamilyView() } label: {
                    LabeledContent {
                        Text(cloud.status.text).foregroundStyle(.secondary)
                    } label: { NativeSettingsLabel("Family Sharing", symbol: "person.2") }
                }
            }
            Section {
                categoryLink(.general)
                categoryLink(.library)
                #if !os(tvOS)
                NavigationLink(value: LibraryRoute.downloads) {
                    LabeledContent {
                        Text(downloads.totalBytes == 0 ? "None" : ByteText.format(downloads.totalBytes)).foregroundStyle(.secondary)
                    } label: { NativeSettingsLabel("Downloads", symbol: "arrow.down.circle") }
                }
                #endif
                categoryLink(.server)
            }
            Section {
                categoryLink(.advanced)
                NavigationLink { PrivacyDetailsView() } label: {
                    NativeSettingsLabel("Privacy", symbol: "hand.raised")
                }
                categoryLink(.about)
            }
        }
    }

    private func categoryLink(_ category: SettingsCategory) -> some View {
        NavigationLink { SettingsView(category: category) } label: {
            NativeSettingsLabel(category.rawValue, symbol: category.symbol)
        }
        .accessibilityIdentifier("settings.\(category)")
    }

    private var profileLabel: some View {
        HStack(spacing: 12) {
            if let profile = profiles.active {
                ProfileAvatarView(profile: profile, size: 44, isLocked: profile.isLocked)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.headline)
                    Text("Profiles & Family").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                NativeSettingsLabel("Profiles & Family", symbol: "person.crop.circle")
            }
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 4)
    }

    private var profileSections: some View {
        Section {
            NavigationLink { ManageProfilesView() } label: { profileLabel }
            Button("Switch Profile") { profiles.lock() }
            NavigationLink { FamilyView() } label: {
                LabeledContent("Family Sharing", value: cloud.status.text)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var appearanceSection: some View {
        @Bindable var model = model
        return Section {
            Picker("Appearance", selection: $model.appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            #if os(iOS)
            .pickerStyle(.inline)
            #endif
        } footer: { Text("Automatic follows your device's appearance.") }
    }

    private var librarySections: some View {
        @Bindable var model = model
        return Group {
            Section {
                LabeledContent("Albums", value: library.albums.count.formatted())
                LabeledContent("Songs", value: library.catalogue.trackCount.formatted())
                Button {
                    model.rescan()
                } label: {
                    HStack {
                        Text(model.isScanning ? "Updating Library…" : "Update Library")
                        Spacer()
                        if model.isScanning { ScanActivityIcon(isActive: true) }
                    }
                }
                .disabled(!canScan)
                LabeledContent("Last Updated", value: model.lastScanText)
                if let failure = model.indexingFailure {
                    Text(failure.title).foregroundStyle(.red)
                    if let detail = failure.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section {
                Toggle("Automatic Library Updates", isOn: $model.watchFolder)
            } footer: {
                Text("Check for new music when you open Gumbo and periodically while you listen.")
            }
        }
    }

    private var serverSections: some View {
        Section {
            LabeledContent("Server", value: model.serverTitle)
            LabeledContent("Status", value: model.isConnected ? "Connected" : "Offline")
            if model.connection != nil, permissions.canManageServer {
                NavigationLink { FolderPickerView(mode: .settings) } label: {
                    LabeledContent("Music Folder", value: model.musicFolderLabel)
                }
                if !model.isConnected {
                    Button(model.isReconnecting ? "Reconnecting…" : "Reconnect") {
                        Task { await model.reconnect() }
                    }
                    .disabled(model.isReconnecting)
                }
                if let error = model.signInError, !model.isReconnecting {
                    Text(error).foregroundStyle(.red)
                }
            }
            Button("Connect Away from Home") { isShowingRemoteAccessHelp = true }
        }
    }

    private var advancedSections: some View {
        @Bindable var model = model
        @Bindable var library = library
        return Group {
            Section {
                Button("Refresh Song Information") { isConfirmingTagRead = true }
                    .disabled(!canScan)
                if model.indexer.isEnriching {
                    LabeledContent("Reading Song Information", value: "\(model.indexer.enrichedCount.formatted()) of \(model.indexer.enrichTotal.formatted())")
                }
                #if os(iOS)
                Toggle("Keep Screen Awake During Updates", isOn: $model.keepsScreenOnWhileScanning)
                #endif
            } header: { Text("Library Maintenance") } footer: {
                Text("Refresh song information after changing album names, artists or artwork in your music files.")
            }
            Section {
                Toggle("Shorter Album Titles", isOn: $library.hidesBracketedTitleParts)
                NavigationLink { GenreNamesView() } label: { Text("Edit Genre Names") }
            } header: { Text("Library Display") } footer: {
                Text("Hide bracketed extras such as “Deluxe Edition” in album titles. Your music files stay unchanged.")
            }
            if !model.legacyLibraryRecoveries.isEmpty {
                Section {
                    Button("Recover a Saved Library") { isRecoveringLegacyLibrary = true }
                } footer: {
                    Text("Bring back favourites, playlists and listening history from an earlier connection.")
                }
            }
            Section {
                NavigationLink { DiagnosticsView() } label: { Text("Diagnostics") }
            } header: { Text("Troubleshooting") } footer: {
                Text("Connection and playback details that can help investigate a problem.")
            }
        }
    }

    private var aboutSections: some View {
        Section {
            LabeledContent("App", value: "Gumbo Music")
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            NavigationLink { ReleaseNotesView() } label: { Text("What's New") }
        }
    }

    private var signOutSection: some View {
        Section {
            Button(library.isDemo ? "Leave Sample Library" : "Sign Out", role: .destructive) {
                isConfirmingSignOut = true
            }
        }
    }
}

/// Neutral native labels reserve blue for actions and selections rather than every icon.
private struct NativeSettingsLabel: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        #if os(macOS)
        Text(title).foregroundStyle(.primary)
        #else
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
        #endif
    }
}

/// Shared by iPhone, iPad, Mac and TV. Only listening data is copied after a named-source confirmation.
private struct LegacyLibraryRecoverySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: LegacyLibraryRecovery?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose the old server whose favourites, playlists and history belong to this connection. Your current edits and the original saved library are kept. Older downloads must be downloaded again.")
                        .font(.callout)
                }
                if let current = model.legacyLibraryRecoveries.first {
                    Section("Current connection") {
                        LabeledContent("Address", value: current.address)
                        LabeledContent("Account", value: current.account)
                    }
                    Section("Earlier libraries") {
                        ForEach(model.legacyLibraryRecoveries) { choice in
                            Button {
                                selected = choice
                                problem = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.legacySourceID)
                                    Text("\(choice.favouritesCount) favourites · \(choice.playlistsCount) playlists · \(choice.historyCount) history entries")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section { Text("No earlier libraries are waiting to be recovered for this connection. Reconnect to your server and finish scanning if needed.") }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red).font(.footnote) }
                }
            }
            .groupedForm()
            .navigationTitle("Recover saved library")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Recover this saved library?", isPresented: Binding(
                get: { selected != nil },
                set: { if !$0 { selected = nil } }
            ), titleVisibility: .visible, presenting: selected) { choice in
                Button("Recover saved library") {
                    problem = model.recoverLegacyLibrary(choice)
                    selected = nil
                    if problem == nil { dismiss() }
                }
                Button("Cancel", role: .cancel) { selected = nil }
            } message: { choice in
                Text("Copy saved listening data from \(choice.legacySourceID) to \(choice.address), signed in as \(choice.account). Existing edits stay in place. This does not transfer passwords or downloaded audio.")
            }
        }
        .sheetDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 440, idealHeight: 560)
        #endif
    }
}

// MARK: - Settings building blocks

/// A titled card of rows with hairlines between them, and an optional line of help under it.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                    .padding(.leading, 12)
            }
            Group(subviews: content()) { rows in
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        rows[index]
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
            }
            .background(Color.groupedCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
    }
}

/// The coloured symbol tile at the start of a row.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon, title, an optional second line, and whatever sits at the trailing edge.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    init(symbol: String, tint: Color, title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

/// A row that is a button, tinted or destructive.
struct SettingsButtonRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void

    init(symbol: String, tint: Color, title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 14) {
                SettingsIcon(symbol: symbol, tint: tint)
                Text(title)
                    .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }
}

/// Secondary text at the trailing edge of a row.
struct SettingsValue: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

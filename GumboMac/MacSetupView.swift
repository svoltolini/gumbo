import AppKit
import GumboCore
import SwiftUI

/// A resizable Mac assistant: steps on the left, content on the right, and actions kept clear
/// of scrolling content. Every step drives the same model as the phone's flow.
struct MacSetupView: View {
    static let minimumSize = CGSize(width: 900, height: 600)

    @Environment(AppModel.self) private var model

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, server, signIn, folder, library

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .server: "Server"
            case .signIn: "Sign In"
            case .folder: "Music Folder"
            case .library: "Library"
            }
        }
    }

    private var step: Step {
        switch model.stage {
        case .welcome: .welcome
        case .discovering: model.pendingServer == nil ? .server : .signIn
        case .chooseFolder: .folder
        case .indexing, .ready: .library
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SetupRail(current: step)
                .frame(width: 220)
            Divider()
            Group {
                switch step {
                case .welcome: MacWelcomeStep()
                case .server: MacServerStep()
                case .signIn: MacSignInStep()
                case .folder: MacFolderStep()
                case .library: MacLibraryStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(step)
            .transition(.opacity)
        }
        .frame(minWidth: Self.minimumSize.width, maxWidth: .infinity,
               minHeight: Self.minimumSize.height, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.22), value: step)
        .bareWindow()
    }
}

// MARK: - Rail

/// Brand mark, the five steps with their state, and a line about privacy at the foot.
private struct SetupRail: View {
    let current: MacSetupView.Step
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gumbo").font(.title2.weight(.semibold))
                    Text("Music").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MacSetupView.Step.allCases) { step in
                    row(step)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 30)
            Spacer()
            Text("Your library.\nYour own space.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35))
    }

    private func row(_ step: MacSetupView.Step) -> some View {
        let isCurrent = step == current
        let isDone = step.rawValue < current.rawValue
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isCurrent || isDone ? Palette.accent : Palette.ink.opacity(0.1))
                    .frame(width: 22, height: 22)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.onAccent)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? Palette.onAccent : .secondary)
                }
            }
            Text(step.title)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Palette.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title)\(isDone ? ", done" : isCurrent ? ", current step" : "")")
    }
}

// MARK: - Page scaffold

/// A step's page: title, a line under it, the content, and the button row along the bottom.
private struct StepPage<Content: View, Buttons: View>: View {
    let title: String
    var subtitle: String? = nil
    /// The folder browser provides its own scrolling and uses the available height.
    var scrollsContent = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if scrollsContent {
                ScrollView {
                    pageContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack(spacing: 10) {
                buttons()
            }
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .kerning(-0.6)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            content()
                .padding(.top, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Welcome

private struct MacWelcomeStep: View {
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloud
    @State private var isJoiningWithLink = false

    var body: some View {
        StepPage(title: "Your music.\nAt home on your Mac.", subtitle: "Connect your Synology and bring your own library to Gumbo Music.") {
            VStack(alignment: .leading, spacing: 24) {
                welcomeRow("Your collection, ready to play", symbol: "externaldrive", detail: "Choose your music folder. Gumbo reads your songs, tags and covers directly from your NAS.")
                welcomeRow("Listen your way", symbol: "headphones", detail: "Stream from your NAS or keep downloads on your devices for offline listening.")
                welcomeRow("A personal library stays personal", symbol: "lock", detail: "No Gumbo account. Your NAS sign-in stays in Keychain, with optional sync to your own devices. Profiles and playlists can sync through iCloud.")
                PrivacyDetailsButton()
                MacCloudLibraryNotice()
                Button("Explore Sample Library") {
                    model.useSampleLibrary()
                    model.openLibrary()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .font(.callout)
            }
        } buttons: {
            if cloud.family?.isReachable != true {
                Button("Join with a Link…") { isJoiningWithLink = true }
            }
            Spacer()
            if let family = cloud.family, family.isReachable {
                Button("Find Servers") { model.findServers() }
                    .disabled(model.isJoiningFamily)
                MacCloudLibraryButton(family: family)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { model.findServers() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(isPresented: $isJoiningWithLink) {
            JoinWithLinkSheet()
        }
    }

    private func welcomeRow(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

// MARK: - Library from iCloud

/// Stays visible on Server too, so moving on before iCloud answers does not hide a saved library.
private struct MacCloudLibraryNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloud
    var showsConnectButton = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "icloud")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                if let family = cloud.family, family.isReachable {
                    Text(cloud.isOwner ? "Your saved library setup" : "Your family’s library setup")
                        .font(.headline)
                    Text(family.serverName).font(.callout.weight(.medium))
                    Text(cloud.currentUserRecordName != nil && cloud.isOwner
                         ? "Use the server and music folder saved in iCloud. If your sign-in has synced with iCloud Keychain, Gumbo can connect without asking again. Otherwise, you can sign in here."
                         : family.familyAccount != nil && family.familyPassword != nil
                         ? "Gumbo can connect with your shared Family Access account and use the music folder already chosen."
                         : "iCloud found your family’s server and music folder. Sign in with your NAS account to continue.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.isJoiningFamily {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Connecting to your library…").font(.callout)
                        }
                    } else if let error = model.signInError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if showsConnectButton {
                        MacCloudLibraryButton(family: family)
                    }
                } else {
                    unavailableLibrary
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var unavailableLibrary: some View {
        switch cloud.status {
        case .off, .syncing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking iCloud for your library…").font(.callout)
            }
            Text("Already use Gumbo on another device? Your saved library will appear here. You can also connect manually.")
                .font(.callout).foregroundStyle(.secondary)
        case .noAccount:
            Text("Already set up on another device?").font(.headline)
            Text("Sign in to the same Apple Account in System Settings to find your saved library, or connect manually.")
                .font(.callout).foregroundStyle(.secondary)
            retrySyncButton
        case .failed:
            Text("Couldn’t check iCloud").font(.headline)
            Text("Try again to find the library from your other device, or connect manually.")
                .font(.callout).foregroundStyle(.secondary)
            retrySyncButton
        case .synced:
            Text("Already set up on another device?").font(.headline)
            Text("No library setup was found in iCloud yet. Open Gumbo on your other device and let it sync, then check again here.")
                .font(.callout).foregroundStyle(.secondary)
            retrySyncButton
        }
    }

    private var retrySyncButton: some View {
        Button("Check iCloud Again") { Task { await cloud.refresh(reason: "Mac setup retry") } }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
    }
}

private struct MacCloudLibraryButton: View {
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloud
    let family: FamilyInfo
    @State private var isStarting = false

    var body: some View {
        Button("Use This Library") {
            guard !isStarting, !model.isJoiningFamily, !model.isSigningIn else { return }
            isStarting = true
            Task {
                // Change the step in the same task that starts connecting. iOS presents a sheet;
                // the Mac must leave Welcome before selecting the server for its Sign In step.
                if model.stage == .welcome { model.stage = .discovering }
                await model.useCloudLibrary(family, isOwner: cloud.currentUserRecordName != nil && cloud.isOwner)
                isStarting = false
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.accent)
        .disabled(isStarting || model.isJoiningFamily || model.isSigningIn)
        .accessibilityIdentifier("setup.useCloudLibrary")
        .help("Connect to \(family.serverName) using its saved music folder")
    }
}

// MARK: - Server

private struct MacServerStep: View {
    @Environment(AppModel.self) private var model
    @State private var selection: DiscoveredServer.ID?
    @State private var address = ""
    @State private var isResolving = false
    @State private var error: String?
    @State private var isReadingGuide = false

    private var servers: [DiscoveredServer] { model.discovery.servers }

    var body: some View {
        StepPage(title: "Find your server", subtitle: "Synology servers on this network appear here. Away from home, enter the address you set up in DSM.") {
            VStack(alignment: .leading, spacing: 14) {
                MacCloudLibraryNotice(showsConnectButton: true)
                Text("Or connect to a server")
                    .font(.headline)
                    .padding(.top, 8)
                List(servers, selection: $selection) { server in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name).font(.body.weight(.medium))
                            Text(server.address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 170)
                .disabled(model.isJoiningFamily)
                .overlay {
                    if servers.isEmpty {
                        HStack(spacing: 8) {
                            if model.discovery.isBrowsing { ProgressView().controlSize(.small) }
                            Text(model.discovery.isBrowsing ? "Looking for music servers…" : "No servers found on this network")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Address, such as myds.synology.me or 192.168.1.40", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                        .disabled(isResolving || model.isJoiningFamily)
                    Button("Connect", action: connect)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isResolving || model.isJoiningFamily)
                    if isResolving { ProgressView().controlSize(.small) }
                }
                Text("HTTPS is the default and needs a trusted certificate matching the address. Tailscale provides network access, but its IP or MagicDNS name may not match DSM's certificate. For an HTTP-only NAS on a trusted private connection, enter its full http:// address and port, then review the warning before signing in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Button("How to reach your NAS from anywhere…") { isReadingGuide = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        } buttons: {
            Button("Back") {
                model.stage = .welcome
                model.discovery.stop()
            }
            .disabled(model.isJoiningFamily)
            Spacer()
            Button("Continue") {
                if let server = servers.first(where: { $0.id == selection }) { model.select(server) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil || model.isJoiningFamily)
        }
        .sheet(isPresented: $isReadingGuide) {
            RemoteAccessGuide()
        }
    }

    private func connect() {
        let entry = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty, !isResolving, !model.isJoiningFamily else { return }
        isResolving = true
        error = nil
        Task {
            do {
                try await model.connect(to: entry)
            } catch {
                self.error = error.localizedDescription
            }
            isResolving = false
        }
    }
}

// MARK: - Sign in

private struct MacSignInStep: View {
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloud
    @State private var account = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var remember = true
    @State private var syncCredentials = false
    @State private var httpAllowed = false
    @FocusState private var focus: Field?

    private enum Field { case account, password, otp }

    var body: some View {
        let server = model.pendingServer
        StepPage(title: "Sign in to \(server?.name ?? "your NAS")", subtitle: "Sign in with your DSM account. Gumbo reads your music through File Station, so nothing needs to be installed on the NAS.") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    label("Server")
                    Text(server.map { "\($0.name)  ·  \($0.address)" } ?? "")
                        .foregroundStyle(.secondary)
                }
                if let server {
                    GridRow {
                        Text("")
                        NASTransportChoice(url: server.baseURL, httpAllowed: $httpAllowed) {
                            guard let url = NASTransportSecurity.httpsAlternative(for: server.baseURL) else { return }
                            password = ""
                            otpCode = ""
                            model.select(DiscoveredServer(name: server.name, baseURL: url, model: server.model))
                        }
                        .disabled(model.isSigningIn)
                    }
                }
                GridRow {
                    label("Account")
                    TextField("", text: $account)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .focused($focus, equals: .account)
                        .accessibilityLabel("NAS account")
                        .accessibilityIdentifier("setup.nasAccount")
                        .onSubmit { focus = .password }
                }
                GridRow {
                    label("Password")
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .focused($focus, equals: .password)
                        .onSubmit { model.needsOTP ? focus = .otp : submit() }
                }
                if model.needsOTP {
                    GridRow {
                        label("Code")
                        TextField("Two-factor code", text: $otpCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .focused($focus, equals: .otp)
                            .onSubmit(submit)
                    }
                }
                GridRow {
                    Text("")
                    Toggle("Remember me on this Mac", isOn: $remember)
                        .disabled(model.isSigningIn)
                }
                if model.supportsCredentialSync {
                    GridRow {
                        Text("")
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Sync sign-in with iCloud Keychain", isOn: $syncCredentials)
                                .disabled(!remember || model.isSigningIn)
                                .accessibilityIdentifier("signIn.syncCredentials")
                            Text("Optional sync keeps your sign-in available on your iPhone, iPad and Mac with the same Apple Account. It does not share your password with your Gumbo family. Turn on Passwords & Keychain in iCloud settings on each device.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 480, alignment: .leading)
                        }
                    }
                }
                if let error = model.signInError {
                    GridRow {
                        Text("")
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } buttons: {
            Button("Back") { model.cancelSignIn() }
                .disabled(model.isSigningIn)
            Spacer()
            if model.isSigningIn {
                ProgressView().controlSize(.small)
                    .padding(.trailing, 6)
            }
            Button("Sign In", action: submit)
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(account.isEmpty || password.isEmpty || model.isSigningIn || !transportAllowed)
        }
        .animation(.easeInOut(duration: 0.2), value: model.needsOTP)
        .onAppear {
            httpAllowed = server.map { NASTransportSecurity.isAllowed($0.baseURL) } ?? false
            syncCredentials = model.syncCredentialsAcrossDevices
            if let familyAccount = model.pendingFamilyAccount {
                account = familyAccount
                password = model.pendingFamilyPassword ?? ""
            } else if let connection = model.connection, let server, NASOrigin(url: connection.baseURL) == NASOrigin(url: server.baseURL) {
                account = connection.account
                if let storedPassword = model.pendingReconnectPassword {
                    password = storedPassword
                }
            } else {
                account = suggestedOwnerAccount(for: server) ?? ""
            }
            if model.needsOTP, !password.isEmpty {
                focus = .otp
            } else {
                focus = account.isEmpty ? .account : .password
            }
        }
        .onChange(of: model.needsOTP) {
            guard model.needsOTP else { return }
            if let pendingPassword = model.pendingReconnectPassword {
                password = pendingPassword
            }
            focus = .otp
        }
        .onChange(of: account) {
            // A different NAS account needs its own explicit choice to sync its password.
            if account != (model.pendingFamilyAccount ?? model.connection?.account) { syncCredentials = false }
        }
        .onChange(of: remember) {
            if !remember { syncCredentials = false }
        }
        .onChange(of: server?.id) {
            syncCredentials = model.syncCredentialsAcrossDevices
            account = model.pendingFamilyAccount ?? suggestedOwnerAccount(for: model.pendingServer) ?? ""
            password = model.pendingFamilyPassword ?? ""
            otpCode = ""
            httpAllowed = model.pendingServer.map { NASTransportSecurity.isAllowed($0.baseURL) } ?? false
        }
    }

    private func suggestedOwnerAccount(for server: DiscoveredServer?) -> String? {
        guard let server, cloud.currentUserRecordName != nil, cloud.isOwner,
              let family = cloud.family,
              let savedOrigin = family.address.flatMap(URL.init(string:)).flatMap(NASOrigin.init(url:)),
              let selectedOrigin = NASOrigin(url: server.baseURL), savedOrigin == selectedOrigin else { return nil }
        // The owner's own account may be suggested; invited members never inherit it.
        return family.serverAccount
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty, transportAllowed else { return }
        Task { await model.signIn(account: account, password: password, otpCode: otpCode, remember: remember, syncCredentials: remember && syncCredentials) }
    }

    private var transportAllowed: Bool {
        model.pendingServer.map { NASOrigin(url: $0.baseURL)?.isHTTPS == true || httpAllowed } ?? false
    }
}

// MARK: - Folder

/// A Finder-like browser: shared folders first, then folders inside the one opened. Double-click
/// or Open goes in; the default button chooses the folder currently open.
private struct MacFolderStep: View {
    @Environment(AppModel.self) private var model
    @State private var trail: [RemoteEntry] = []
    @State private var entries: [RemoteEntry] = []
    @State private var selection: RemoteEntry.ID?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        StepPage(title: "Choose your music folder", subtitle: "Open the shared folder that holds your music and choose it, or a folder inside it if the share also holds other media. Everything inside is indexed.", scrollsContent: false) {
            VStack(alignment: .leading, spacing: 10) {
                pathBar
                List(entries, selection: $selection) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: trail.isEmpty ? "externaldrive.fill" : "folder.fill")
                            .foregroundStyle(trail.isEmpty ? .secondary : Color.accentColor)
                        Text(entry.name)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(entry) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .overlay {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading folders…").foregroundStyle(.secondary)
                        }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding()
                    } else if entries.isEmpty {
                        Text(trail.isEmpty ? "No shared folders are visible to this account." : "No folders inside")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } buttons: {
            Button("Back") {
                if trail.isEmpty {
                    model.cancelFolderChoice()
                } else {
                    trail.removeLast()
                    selection = nil
                }
            }
            Button("Open") {
                if let entry = entries.first(where: { $0.id == selection }) { open(entry) }
            }
            .disabled(selection == nil)
            Spacer()
            Button(trail.last.map { "Use “\($0.name)”" } ?? "Use This Folder") {
                if let current = trail.last { model.chooseMusicFolder(path: current.path, showsProgress: true) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .keyboardShortcut(.defaultAction)
            .disabled(trail.isEmpty)
        }
        .task(id: trail.last?.path) { await load() }
    }

    /// Where the browser is: the shares, then each folder opened.
    private var pathBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            Text("Shared folders")
                .foregroundStyle(trail.isEmpty ? .primary : .secondary)
            ForEach(trail) { folder in
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(folder.name)
                    .foregroundStyle(folder.id == trail.last?.id ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .font(.callout)
    }

    private func open(_ entry: RemoteEntry) {
        trail.append(entry)
        selection = nil
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            entries = try await model.loadFolders(in: trail.last?.path)
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Library

private struct MacLibraryStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library

    private var indexer: LibraryIndexer { model.indexer }

    var body: some View {
        StepPage(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.indexedCount, format: .number)
                        .font(.system(size: 54, weight: .light))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(model.indexedCount)))
                        .animation(reduceMotion ? nil : .default, value: model.indexedCount)
                    Text("songs")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Group {
                    if model.isDemo {
                        ProgressView(value: Double(model.demoCount) / Double(SampleLibrary.displayedTrackTotal))
                    } else if indexer.isScanning {
                        ProgressView()
                    } else if model.indexingFailure != nil {
                        ProgressView(value: 0)
                    } else {
                        ProgressView(value: indexer.enrichProgress)
                    }
                }
                .frame(width: 280)
                .animation(.easeOut(duration: 0.25), value: indexer.enrichProgress)
            }
        } buttons: {
            if model.indexingFailure != nil {
                Button("Choose Another Folder") { model.chooseAnotherFolder() }
                Spacer()
                Button("Try Again") { model.retryIndexing() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Open Library") { model.openLibrary() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isIndexed)
            }
        }
    }

    private var title: String {
        if let failure = model.indexingFailure { return failure.title }
        return model.isIndexed ? "Your library is ready" : "Building your library"
    }

    private var subtitle: String? {
        if let failure = model.indexingFailure { return failure.detail }
        if model.isDemo {
            return model.isIndexed ? library.catalogue.detail : "Reading tags, artwork and folder structure…"
        }
        switch indexer.phase {
        case .scanning: return "\(indexer.foldersScanned.formatted()) folders scanned"
        case .enriching: return "\(library.catalogue.detail). Tags and covers keep arriving in the background."
        case .done: return library.catalogue.detail
        default: return "Reading tags, artwork and folder structure…"
        }
    }
}

// MARK: - Snapshots

/// Development aid: `--snapshot <directory>` renders every setup step to a PNG and quits, so the
/// layout can be checked without screen recording rights. The window draws its own contents.
@MainActor
enum MacSetupSnapshots {
    static func runIfRequested(model: AppModel) {
        // The app is sandboxed, so the images land in its own temporary folder.
        guard ProcessInfo.processInfo.arguments.contains("--snapshot") else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: "setup-snapshots", directoryHint: .isDirectory)
        NSLog("Gumbo setup snapshots: %@", directory.path)
        Task { await run(model: model, into: directory) }
    }

    private static func run(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only the stage and the pending server are touched, and both are put back at the end.
        let originalStage = model.stage
        let steps: [(String, () -> Void)] = [
            ("1-welcome", { model.stage = .welcome }),
            ("2-server", { model.pendingServer = nil; model.stage = .discovering }),
            ("3-signin", { model.stage = .discovering; model.pendingServer = DiscoveredServer(name: "Synology DS224+", host: "192.168.1.40", port: 5001, model: "DS224+") }),
            ("4-folder", { model.pendingServer = nil; model.stage = .chooseFolder }),
            ("5-library", { model.stage = .indexing }),
        ]
        try? await Task.sleep(for: .seconds(1.5))
        for (name, apply) in steps {
            apply()
            try? await Task.sleep(for: .seconds(1.4))
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appending(path: "\(name).png"))
            }
        }
        model.pendingServer = nil
        model.stage = originalStage
        try? await Task.sleep(for: .seconds(0.5))
        NSApp.terminate(nil)
    }
}

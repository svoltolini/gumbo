import GumboCore
import SwiftUI

/// An explicit protocol and address; discovery only supplies editable suggestions.
struct NASConnectionDraft {
    var provider: NASProviderKind = .synology
    var address = ""
    var share = ""
    var domain = ""
    var requiresEncryption = true

    init(server: DiscoveredServer? = nil) {
        guard let server else { return }
        provider = server.providerKind
        address = server.baseURL.absoluteString
        share = server.provider?.share ?? ""
        domain = server.provider?.domain ?? ""
        requiresEncryption = server.provider?.requiresEncryption ?? true
    }

    var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (provider != .smb || !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var addressPrompt: String {
        switch provider {
        case .synology: "NAS name or https://nas.example.com:5001"
        case .webDAV: "https://nas.example.com:5006/music/"
        case .smb: "NAS name or smb://192.168.1.40"
        }
    }

    var explanation: String {
        switch provider {
        case .synology:
            "Uses Synology File Station. HTTPS needs a trusted certificate matching the address. For an HTTP-only server on a trusted private connection, enter its full http:// address and port, then review the warning before signing in."
        case .webDAV:
            "Enable WebDAV on your NAS and enter its full HTTPS address, port and folder path. A trusted certificate matching the address is required. Gumbo reads your files. Editing tags or deleting files needs a separately configured NAS helper."
        case .smb:
            "Enable SMB 2 or 3 on your NAS and enter a shared folder name. Encryption is required by default. Use your home network or a private VPN for remote access; do not expose SMB to the internet."
        }
    }
}

/// Shared native fields keep the iPhone, TV and Mac connection choices consistent.
struct NASProviderFields: View {
    @Binding var draft: NASConnectionDraft
    var submit: () -> Void

    var body: some View {
        Picker("Connection", selection: $draft.provider) {
            Text("Synology · File Station").tag(NASProviderKind.synology)
            Text("WebDAV · HTTPS").tag(NASProviderKind.webDAV)
            Text("SMB · Shared folder").tag(NASProviderKind.smb)
        }
        TextField("Address", text: $draft.address, prompt: Text(draft.addressPrompt))
            .noAutocapitalization()
            .autocorrectionDisabled()
            .urlKeyboard()
            .accessibilityLabel("Server address")
            .submitLabel(.go)
            .onSubmit(submit)
        if draft.provider == .smb {
            TextField("Shared folder", text: $draft.share, prompt: Text("Shared folder, such as Music"))
                .noAutocapitalization().autocorrectionDisabled()
                .accessibilityLabel("Shared folder")
            TextField("Domain or workgroup", text: $draft.domain, prompt: Text("Domain or workgroup (optional)"))
                .noAutocapitalization().autocorrectionDisabled()
            Toggle("Require SMB encryption", isOn: $draft.requiresEncryption)
            if !draft.requiresEncryption {
                Label("Signing stays required, but music may travel without encryption. Use only a trusted private connection.", systemImage: "exclamationmark.lock.open")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NASConnectionDraft
    @State private var isResolving = false
    @State private var error: String?
    @State private var isReadingGuide = false

    init(server: DiscoveredServer? = nil) {
        _draft = State(initialValue: NASConnectionDraft(server: server))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NASProviderFields(draft: $draft, submit: submit)
                        .disabled(isResolving)
                } header: {
                    Text("Server")
                } footer: {
                    Text(draft.explanation)
                }
                Section {
                    Button { isReadingGuide = true } label: {
                        Label("Connecting your NAS", systemImage: "book")
                    }
                    .disabled(isResolving)
                } footer: {
                    Text("For NAS brands such as QNAP, TrueNAS or UGREEN, choose the protocol enabled on your server. Available features depend on that service and your account’s permissions.")
                }
                if isResolving {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking the address…").foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .groupedForm()
            .navigationTitle("Connect")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isResolving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: submit).disabled(!draft.canConnect || isResolving)
                }
            }
            .interactiveDismissDisabled(isResolving)
            .sheet(isPresented: $isReadingGuide) { RemoteAccessGuide() }
        }
        .sheetDetents([.large])
    }

    private func submit() {
        guard draft.canConnect, !isResolving else { return }
        let selected = draft
        isResolving = true
        error = nil
        Task {
            do {
                try await model.connect(to: selected.address, provider: selected.provider, share: selected.share,
                                        domain: selected.domain, requiresEncryption: selected.requiresEncryption)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isResolving = false
        }
    }
}

private struct ReauthenticationSheet: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.stage == .ready ? model.pendingServer : nil },
            set: { if $0 == nil { model.cancelSignIn() } }
        )) { server in
            LoginSheet(server: server)
        }
    }
}

private struct DownloadErrorAlert: ViewModifier {
    @Environment(DownloadManager.self) private var downloads

    func body(content: Content) -> some View {
        content.alert("Download couldn't finish", isPresented: Binding(
            get: { downloads.lastError != nil },
            set: { if !$0 { downloads.clearError() } }
        )) {
            Button("OK") { downloads.clearError() }
        } message: {
            Text(downloads.lastError ?? "Reconnect to your NAS and try again.")
        }
    }
}

/// Reports a problem with a profile's files. Reading and writing fail differently: a document that
/// cannot be read keeps its profile closed, so that alert also offers the way past the picker.
private struct ProfileSaveErrorAlert: ViewModifier {
    @Environment(ProfileStore.self) private var profiles

    func body(content: Content) -> some View {
        content.alert(profiles.persistenceFailure?.title ?? "Profile couldn't be saved", isPresented: Binding(
            get: { profiles.persistenceFailure != nil },
            set: { if !$0 { profiles.dismissPersistenceError() } }
        )) {
            if !profiles.isProfileIndexReadable {
                Button("Try Again") { Task { profiles.retryProfileIndex() } }
                Button("Not Now", role: .cancel) { profiles.dismissPersistenceError() }
            } else if profiles.canOpenWithoutSavedData {
                Button("Open Without Saved Data", role: .destructive) {
                    // After the alert has let go of its binding, so a failure here is reported.
                    Task { profiles.openWithoutSavedData() }
                }
                Button("Not Now", role: .cancel) { profiles.dismissPersistenceError() }
            } else {
                Button("OK") { profiles.dismissPersistenceError() }
            }
        } message: {
            Text(profiles.persistenceFailure?.message ?? "Check the available storage on this device and try again.")
        }
    }
}

extension View {
    func reauthenticationSheet() -> some View { modifier(ReauthenticationSheet()) }
    func downloadErrorAlert() -> some View { modifier(DownloadErrorAlert()) }
    func profileSaveErrorAlert() -> some View { modifier(ProfileSaveErrorAlert()) }
}

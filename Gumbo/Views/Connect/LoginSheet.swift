import GumboCore
import SwiftUI

/// Account sign-in for the selected NAS service.
struct LoginSheet: View {
    let server: DiscoveredServer
    @Environment(AppModel.self) private var model
    @State private var account = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var remember = true
    @State private var syncCredentials = false
    @State private var httpAllowed = false
    @FocusState private var focus: Field?

    private enum Field { case account, password, otp }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: server.name)
                    LabeledContent("Address", value: server.address)
                    NASTransportChoice(server: server, httpAllowed: $httpAllowed) {
                        guard let url = NASTransportSecurity.httpsAlternative(for: server.baseURL) else { return }
                        model.select(DiscoveredServer(name: server.name, baseURL: url, model: server.model))
                    }
                    .disabled(model.isSigningIn)
                }
                Section {
                    TextField("Account", text: $account)
                        .textContentType(.username)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                        .focused($focus, equals: .account)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(model.needsOTP ? .next : .go)
                        .onSubmit { model.needsOTP ? focus = .otp : submit() }
                    if model.needsOTP {
                        TextField("Two-factor code", text: $otpCode)
                            .textContentType(.oneTimeCode)
                            .numberKeyboard()
                            .focused($focus, equals: .otp)
                    }
                    Toggle("Remember me", isOn: $remember)
                        .disabled(model.isSigningIn)
                    if model.supportsCredentialSync {
                        Toggle("Sync sign-in with iCloud Keychain", isOn: $syncCredentials)
                            .disabled(!remember || model.isSigningIn)
                            .accessibilityIdentifier("signIn.syncCredentials")
                    }
                } header: {
                    Text(server.providerKind == .synology ? "DSM account" : "NAS account")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(server.signInExplanation)
                        if model.supportsCredentialSync {
                            Text("Optional sign-in sync uses iCloud Keychain on your iPhone, iPad and Mac with the same Apple Account. It does not share your password with your Gumbo family. Turn on Passwords & Keychain in iCloud settings on each device.")
                        }
                    }
                }
                if let error = model.signInError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .groupedForm()
            .animation(.easeInOut(duration: 0.25), value: model.signInError)
            .animation(.easeInOut(duration: 0.25), value: model.needsOTP)
            .navigationTitle("Sign in")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelSignIn() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSigningIn {
                        ProgressView()
                    } else {
                        Button("Sign in", action: submit)
                            .disabled(account.isEmpty || password.isEmpty || !transportAllowed)
                    }
                }
            }
            .interactiveDismissDisabled(model.isSigningIn)
            .onAppear {
                httpAllowed = NASTransportSecurity.isAllowed(server.baseURL)
                syncCredentials = model.syncCredentialsAcrossDevices
                if let familyAccount = model.pendingFamilyAccount {
                    account = familyAccount
                    password = model.pendingFamilyPassword ?? ""
                } else if let connection = model.connection, server.matches(connection: connection) {
                    account = connection.account
                    if let storedPassword = model.pendingReconnectPassword {
                        password = storedPassword
                    }
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
            .onChange(of: server.id) {
                syncCredentials = model.syncCredentialsAcrossDevices
                account = model.pendingFamilyAccount ?? ""
                password = model.pendingFamilyPassword ?? ""
                otpCode = ""
                httpAllowed = NASTransportSecurity.isAllowed(server.baseURL)
            }
        }
        .sheetDetents([.medium, .large])
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty, transportAllowed else { return }
        Task {
            await model.signIn(account: account, password: password, otpCode: otpCode, remember: remember, syncCredentials: remember && syncCredentials)
        }
    }

    private var transportAllowed: Bool {
        server.allowsSignIn(httpAllowed: httpAllowed)
    }
}

/// A local choice made before credentials are sent. Merely displaying an HTTP address grants nothing.
struct NASTransportChoice: View {
    let server: DiscoveredServer
    private var url: URL { server.baseURL }
    @Binding var httpAllowed: Bool
    let useHTTPS: () -> Void

    var body: some View {
        if server.providerKind == .smb {
            VStack(alignment: .leading, spacing: 5) {
                Label(server.provider?.requiresEncryption != false ? "Encrypted SMB required" : "Signed SMB required",
                      systemImage: server.provider?.requiresEncryption != false ? "lock.fill" : "checkmark.shield")
                    .font(.footnote)
                if server.provider?.requiresEncryption == false {
                    Text("Signing protects against changes in transit; it does not encrypt your music. Use a trusted private connection.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if server.providerKind == .synology, NASOrigin(url: url)?.isHTTPS == false {
            VStack(alignment: .leading, spacing: 8) {
                Label("HTTP sends credentials in cleartext", systemImage: "exclamationmark.lock.open")
                    .foregroundStyle(.red)
                    .fontWeight(.medium)
                Text("Your password and music can be read by anyone on this network. HTTPS is strongly recommended. For secure remote access, Tailscale provides an encrypted connection to your NAS without opening ports. Use HTTP only on a private network you fully trust.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use HTTPS Instead", action: useHTTPS)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .foregroundStyle(Palette.onAccent)
                    .controlSize(.small)
                Toggle("I understand the risk — allow HTTP for this address", isOn: Binding(
                    get: { httpAllowed },
                    set: { allowed in
                        if allowed { NASTransportSecurity.allowHTTP(url) }
                        else { NASTransportSecurity.revokeHTTP(url) }
                        httpAllowed = allowed
                    }
                ))
                .font(.footnote)
            }
        } else if NASOrigin(url: url)?.isHTTPS == true {
            Label("Encrypted connection (HTTPS)", systemImage: "lock.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        }
    }
}

// Shared with the native Mac setup. A nil HTTP origin must never match two SMB connections.
extension DiscoveredServer {
    func matches(connection: ServerConnection) -> Bool {
        guard providerKind == connection.providerKind else { return false }
        if let provider { return provider.sourceID(account: connection.account) == connection.sourceID }
        guard providerKind == .synology, let origin = NASOrigin(url: baseURL) else { return false }
        return origin == NASOrigin(url: connection.baseURL)
    }

    func allowsSignIn(httpAllowed: Bool) -> Bool {
        switch providerKind {
        case .smb: return provider?.kind == .smb
        case .webDAV: return provider?.kind == .webDAV && baseURL.scheme?.lowercased() == "https"
        case .synology: return NASOrigin(url: baseURL)?.isHTTPS == true || httpAllowed
        }
    }

    var signInExplanation: String {
        switch providerKind {
        case .synology: "Sign in with your DSM account. Gumbo reads your music through File Station."
        case .webDAV: "Use a NAS account with permission to read this WebDAV folder. WebDAV must already be enabled on your server."
        case .smb: "Use a NAS account with permission to read this shared folder. SMB 2 or 3 must already be enabled on your server."
        }
    }
}

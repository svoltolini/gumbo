import GumboCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ServerDiscoveryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var isEnteringAddress = false
    @State private var suggestedServer: DiscoveredServer?
    @State private var suggestionError: String?
    @State private var checkingServerID: DiscoveredServer.ID?
    @State private var isReadingGuide = false
    @State private var hasWaited = false

    private var servers: [DiscoveredServer] { model.discovery.servers }

    var body: some View {
        SetupPage(step: .server, showsBack: true, contentTitle: "On your network") {
            list
        }
        .gumboBackground(Palette.neutralTint)
        .navigationTitle("On your network")
        .largeTitle()
        .task {
            try? await Task.sleep(for: .seconds(4))
            hasWaited = true
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings with Local Network access turned on.
            if phase == .active, model.discovery.isLocalNetworkDenied { model.discovery.start() }
        }
        .sheet(isPresented: $isEnteringAddress) {
            ConnectSheet(server: suggestedServer, error: suggestionError)
        }
        .sheet(isPresented: $isReadingGuide) {
            RemoteAccessGuide()
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(servers) { server in
                    Button {
                        if server.providerKind == .synology {
                            check(server)
                        } else {
                            suggestedServer = server
                            suggestionError = nil
                            isEnteringAddress = true
                        }
                    } label: {
                        ServerRow(title: server.name, subtitle: server.address, badge: server.providerKind.title,
                                  isChecking: checkingServerID == server.id)
                    }
                    .disabled(checkingServerID != nil)
                }
                if servers.isEmpty, model.discovery.isLocalNetworkDenied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Allow Local Network access")
                            .font(.body.weight(.medium))
                        Text("Gumbo needs Local Network access to find your NAS. Turn it on for Gumbo in Settings, or enter its address below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        #if os(iOS)
                        Button("Open Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                        #endif
                    }
                    .padding(.vertical, 6)
                } else if servers.isEmpty, hasWaited {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No servers found yet")
                            .font(.body.weight(.medium))
                        Text("Make sure this device is on the same Wi-Fi as your NAS, or enter its address below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                Button {
                    suggestedServer = nil
                    suggestionError = nil
                    isEnteringAddress = true
                } label: {
                    ServerRow(title: "Enter an address", subtitle: "Your NAS name, IP address or WebDAV address", badge: nil, symbol: "globe")
                }
                Button {
                    isReadingGuide = true
                } label: {
                    ServerRow(title: "Connecting your NAS", subtitle: "Choose a connection at home or away", badge: nil, symbol: "book")
                }
            } header: {
                HStack(spacing: 8) {
                    if model.discovery.isBrowsing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(!servers.isEmpty ? "Found on your network"
                         : model.discovery.isBrowsing ? "Looking for music servers…" : "No servers found")
                }
                .textCase(nil)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            }
        }
        .hiddenScrollBackground()
        .groupedList()
        .connectColumn(width: 640)
    }

    /// A found DSM is checked before sign-in. When its address can't be used, typically for a
    /// certificate that doesn't cover it, the address form opens with the reason, ready for the
    /// NAS's hostname instead.
    private func check(_ server: DiscoveredServer) {
        guard checkingServerID == nil else { return }
        checkingServerID = server.id
        Task {
            defer { checkingServerID = nil }
            do {
                try await model.connect(to: server)
            } catch is CancellationError {
            } catch {
                suggestedServer = server
                suggestionError = error.localizedDescription
                isEnteringAddress = true
            }
        }
    }
}

private struct ServerRow: View {
    let title: String
    let subtitle: String
    let badge: String?
    var symbol = "externaldrive.fill"
    var isChecking = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(badge.map { "\(subtitle) · \($0)" } ?? subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isChecking {
                ProgressView()
                    .accessibilityLabel("Checking the address")
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

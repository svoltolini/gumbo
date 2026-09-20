import SwiftUI

/// Route choices stay explicit: network access, DSM sign-in and family sync are separate steps.
struct RemoteAccessGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("At home, connect using your NAS's local address. Away from home, use a private connection such as Tailscale or an HTTPS address you have already configured.")
                }
                Section {
                    Text("Tailscale is an optional service that connects your devices to your NAS without setting up public port forwarding.")
                    instruction("1. Set up the NAS", "In Synology Package Center, install Tailscale, open it and sign in. Follow the official guide for your DSM version.")
                    instruction("2. Connect this device", "Install and turn on Tailscale on each supported device you want to use with Gumbo. Sign in to the same Tailscale network, or accept a share for the NAS.")
                    instruction("3. Choose the address", "Check the certificate assigned to DSM under Control Panel › Security › Certificate. For HTTPS, use a hostname covered by that certificate and make sure it reaches your NAS. A Tailscale IP or MagicDNS name is not automatically covered.")
                    documentationLink("Tailscale's Synology setup guide", url: "https://tailscale.com/docs/integrations/synology")
                    documentationLink("Tailscale's HTTPS certificate guide", url: "https://tailscale.com/docs/how-to/set-up-https-certificates")
                } header: {
                    Text("Remote access with Tailscale")
                }
                Section {
                    Text("Enter the full HTTPS address and DSM port, usually https://your-nas-name:5001. If you want to use the full MagicDNS name, including .ts.net, DSM must serve a valid certificate for that name. Tailscale's private connection does not configure this automatically.")
                    Text("For an HTTP-only NAS on a trusted private connection, explicitly enter http:// followed by its address and port, usually 5000. Review Gumbo's warning before signing in. If you rely on Tailscale to protect this route, keep it connected on both devices; Gumbo cannot verify that it is active.")
                    Text("Sign in with your DSM username, password and verification code if requested. Tailscale access does not replace your NAS account.")
                } header: {
                    Text("Connect in Gumbo")
                }
                Section {
                    Text("Each family member needs network access to the NAS and permission to read its music. You can share the NAS through Tailscale without giving access to your other devices.")
                    Text("A Gumbo family invitation syncs profiles and the family's configured server details through iCloud. It does not install Tailscale or grant access to its network.")
                    documentationLink("Share a NAS with Tailscale", url: "https://tailscale.com/docs/features/sharing")
                } header: {
                    Text("Family and other devices")
                } footer: {
                    Text("Apple Watch needs its own reachable network path for downloads. A working Tailscale connection on your iPhone does not establish independent Watch access. Download music before leaving a supported connection.")
                }
                Section {
                    Text("If you already have a remote HTTPS address, enter its full address and port. Use a valid certificate matching that hostname. Your NAS and router administrator must configure and maintain remote access; adding a name alone does not make the server reachable.")
                } header: {
                    Text("An existing HTTPS address")
                }
                Section {
                    Text("If the server cannot be reached, check that the NAS is online, Tailscale is connected on both devices, and your account has access. Check the full hostname and DSM port. If HTTPS answers with a certificate error, first try the hostname already covered by the NAS's trusted certificate. If that certificate is expired or untrusted, correct it in DSM.")
                    Text("Test your chosen route away from home before relying on it. If you change the address in Gumbo, sign in again and verify family access for that connection.")
                } header: {
                    Text("If the connection fails")
                }
            }
            .groupedForm()
            .navigationTitle("Remote Access")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetDetents([.large])
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 500, idealHeight: 660)
        #endif
    }

    private func instruction(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func documentationLink(_ title: String, url: String) -> some View {
        #if os(tvOS)
        Text("Find the official guide at \(url) on your phone or computer.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        #else
        if let destination = URL(string: url) {
            Link(destination: destination) { Label(title, systemImage: "arrow.up.right.square") }
        }
        #endif
    }
}

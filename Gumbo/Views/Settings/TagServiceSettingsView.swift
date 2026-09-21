import GumboCore
import SwiftUI

struct TagServiceSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(ProfileStore.self) private var profiles
    @State private var address = ""
    @State private var token = ""
    @State private var confirmsFolder = false
    @State private var allowsDeletion = false
    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text("Save tag changes on your NAS without sending each music file to this device and back.")
                Text("This optional helper must be installed by the NAS owner. Listening and ordinary downloads don't need it.")
                    .foregroundStyle(.secondary)
                Link("Installation instructions", destination: URL(string: "https://github.com/svoltolini/gumbo/tree/main/Tools/GumboTagService")!)
            }
            if let configured = model.tagServiceConfiguration {
                Section {
                    LabeledContent("Status", value: "Enabled")
                    LabeledContent("Helper", value: configured.endpoint.host() ?? "")
                    LabeledContent("Music folder", value: configured.libraryRoot)
                    LabeledContent("Reviewed file deletion", value: configured.allowsReviewedDeletion == true ? "Enabled" : "Off")
                    Button("Turn Off", role: .destructive) { model.disableTagService(); message = nil }
                        .disabled(!profiles.canManageProfiles || library.metadataWriter.isWriting || library.isDeletingFiles)
                } footer: {
                    Text("Gumbo uses this helper for tag edits. If it can't confirm an edit, it reports the problem so you can check the file before trying again.")
                }
            } else {
                Section {
                    TextField("HTTPS helper address", text: $address)
                        .noAutocapitalization().autocorrectionDisabled()
                    SecureField("Private helper token", text: $token)
                        .noAutocapitalization().autocorrectionDisabled()
                    Toggle("The helper's music folder matches this library", isOn: $confirmsFolder)
                    Toggle("Allow reviewed file deletion", isOn: $allowsDeletion)
                    Text("Optional. The helper must also allow deletion. Albums and damaged files still need your review and confirmation before permanent deletion.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let path = model.musicPath { Text(path).font(.footnote).foregroundStyle(.secondary) }
                    Button(isChecking ? "Checking…" : "Check and Enable") {
                        let expectedSession = profiles.sessionID
                        let expectedConnection = model.connection
                        let submittedAddress = address, submittedToken = token
                        let submittedAllowsDeletion = allowsDeletion
                        isChecking = true; message = nil
                        Task {
                            guard profiles.sessionID == expectedSession, model.connection == expectedConnection,
                                  profiles.canManageProfiles else { isChecking = false; return }
                            do { try await model.configureTagService(address: submittedAddress, token: submittedToken, allowsReviewedDeletion: submittedAllowsDeletion); token = "" }
                            catch {
                                if profiles.sessionID == expectedSession, model.connection == expectedConnection {
                                    message = error.localizedDescription
                                }
                            }
                            isChecking = false
                        }
                    }
                    .disabled(isChecking || !confirmsFolder || address.isEmpty || token.isEmpty || !profiles.canManageProfiles || !model.isConnected || library.metadataWriter.isWriting || library.isDeletingFiles)
                } header: { Text("Connect the Helper") } footer: {
                    Text("Mount the selected library folder as the helper's music root. The private token is saved on this device, separately from your NAS password. Family members don't receive it.")
                }
            }
            if let message { Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
        }
        .groupedForm()
        .navigationTitle("Faster Tag Editing")
        .onAppear { address = model.tagServiceConfiguration?.endpoint.absoluteString ?? "" }
        .onChange(of: profiles.sessionID) { _, _ in token = ""; confirmsFolder = false; allowsDeletion = false; message = nil }
        .onChange(of: model.connection) { _, _ in token = ""; confirmsFolder = false; allowsDeletion = false; message = nil }
        .onDisappear { token = "" }
    }
}

import GumboCore
import SwiftUI

/// Joining a family by pasting its invitation link. The system normally hands the link to Gumbo on
/// its own; this is the way in when it opened in a browser instead, or came through a chat app
/// that shows it as text. Any Apple Account can join: Family Sharing is not involved.
struct JoinWithLinkSheet: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var isJoining = false
    @State private var problem: String?

    private var url: URL? { CloudSync.invitationURL(in: link) }

    /// Shown once something is typed that can't be an invitation, so Join isn't greyed out unexplained.
    private var linkProblem: String? {
        guard url == nil, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "This isn't a Gumbo invitation link. It starts with icloud.com/share."
    }

    var body: some View {
        NavigationStack {
            Group {
                #if os(tvOS)
                ScrollView {
                    VStack(spacing: 28) {
                        SettingsGroup(title: "Invitation", footer: "The link starts with icloud.com/share. It works with any Apple Account, in any country; you don't need to be in the owner's Family Sharing group. If the link opened in your browser and said it wasn't valid, paste it here instead.") {
                            HStack(spacing: 14) {
                                SettingsIcon(symbol: "link", tint: .blue)
                                TextField("Paste the invitation link", text: $link)
                                    .noAutocapitalization()
                                    .autocorrectionDisabled()
                                    .disabled(isJoining)
                                #if !os(tvOS)
                                PasteButton(payloadType: String.self) { strings in
                                    link = strings.first ?? ""
                                }
                                .labelStyle(.iconOnly)
                                .buttonBorderShape(.capsule)
                                #endif
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        if let problem = problem ?? linkProblem {
                            Text(problem)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 12)
                        }
                        if isJoining {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Joining the family…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .background(Palette.paper)
                #else
                Form {
                    Section {
                        TextField("Invitation link", text: $link)
                            .noAutocapitalization()
                            .autocorrectionDisabled()
                            .disabled(isJoining)
                        PasteButton(payloadType: String.self) { strings in link = strings.first ?? "" }
                            .disabled(isJoining)
                    } header: {
                        Text("Invitation")
                    } footer: {
                        Text("The link starts with icloud.com/share. It works with any Apple Account, in any country; you don't need to be in the owner's Family Sharing group. If the link opened in your browser and said it wasn't valid, paste it here instead.")
                    }
                    if let problem = problem ?? linkProblem {
                        Section { Text(problem).font(.callout).foregroundStyle(.red) }
                    }
                    if isJoining {
                        Section { ProgressView("Joining the family…") }
                    }
                }
                .groupedForm()
                #endif
            }
            .navigationTitle("Join a Family")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isJoining)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") { join() }
                        .disabled(url == nil || isJoining)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 340, idealHeight: 440)
        #endif
    }

    private func join() {
        guard let url else { return }
        isJoining = true
        problem = nil
        Task {
            problem = await cloud.accept(url: url)
            isJoining = false
            if problem == nil { dismiss() }
        }
    }
}

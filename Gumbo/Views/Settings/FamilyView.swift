import GumboCore
import CloudKit
import SwiftUI

#if os(tvOS)
/// The family's plumbing: iCloud sync, the NAS account members connect with, and leaving. Who is
/// in the family, and inviting, live on the Profiles screen, since everyone who joins is a profile.
struct FamilyView: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(ProfileStore.self) private var profiles
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @State private var isWorkingOnAccess = false
    @State private var isEnteringAccount = false
    @State private var isConfirmingRemoveAccess = false
    @State private var isConfirmingStop = false
    @State private var isConfirmingManualRevocation = false
    @State private var isJoiningWithLink = false
    @State private var problem: String?

    private var permissions: Permissions { Permissions(profiles: profiles, cloud: cloud) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                SettingsGroup(title: "iCloud", footer: footer) {
                    SettingsRow(symbol: "icloud.fill", tint: .blue, title: "Sync") {
                        SettingsValue(cloud.status.text)
                    }
                }

                if permissions.canManageFamily, model.connection?.isHomeOnly == true {
                    SettingsGroup(title: "Reaching the server", footer: "Members need a route to this NAS. Tailscale is an optional way to connect remotely. When you change the server address or owner account, verify family access again for that connection.") {
                        SettingsRow(symbol: "house.fill", tint: .orange, title: "Home network only") {
                            EmptyView()
                        }
                    }
                }

                if cloud.isActive, permissions.canManageFamily, !model.isDemo {
                    familyAccessGroup
                }

                #if !os(tvOS)
                if (cloud.isActive && cloud.isOwner && !cloud.isShared) || cloud.needsFamilyInvitation {
                    SettingsGroup(title: cloud.needsFamilyInvitation ? "Reconnect with your family" : "Joining someone else's family", footer: "Invitations are icloud.com/share links made in Gumbo. Opening one on this device normally joins straight away; if it opened in a browser instead, paste it here. Any Apple Account can join, wherever it lives; Family Sharing is not needed.") {
                        SettingsButtonRow(symbol: "link", tint: .blue, title: "Join with an invitation link") {
                            isJoiningWithLink = true
                        }
                    }
                }
                #endif

                if cloud.isActive || (model.familyRevocationPending && cloud.currentUserRecordName != nil) {
                    if (cloud.isOwner && (cloud.isShared || model.familyRevocationPending) && permissions.canManageFamily) || (!cloud.isOwner && permissions.canLeave) {
                        SettingsGroup(footer: cloud.isOwner ? stopSharingNotice : "Your profile stays on this device; the family's profiles go.") {
                            SettingsButtonRow(symbol: cloud.isOwner ? "xmark.circle" : "rectangle.portrait.and.arrow.right", tint: .red, title: model.familyRevocationPending ? "Finish stopping sharing" : (cloud.isOwner ? "Stop sharing" : "Leave family"), role: .destructive) {
                                isConfirmingStop = true
                            }
                            if model.familyRevocationPending && !model.canManageNASAccounts && !cloud.isShared {
                                SettingsButtonRow(symbol: "checkmark.shield", tint: .primary, title: "I changed the NAS account") {
                                    isConfirmingManualRevocation = true
                                }
                            }
                        }
                        .disabled(isWorkingOnAccess)
                    }
                }

                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .gumboBackground(player.tint)
        .navigationTitle("Family")
        .inlineTitle()
        .pullToRefresh { await cloud.refresh(reason: "pull") }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await cloud.refresh(reason: "toolbar") } }
            }
            #endif
        }
        .confirmationDialog(cloud.isOwner ? "Stop sharing the family?" : "Leave the family?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
            Button(cloud.isOwner ? "Stop sharing" : "Leave", role: .destructive) {
                guard let authorization = cloud.sharingAuthorization() else { return }
                performAccess(requiresOwner: cloud.isOwner) {
                    await model.stopFamilySharing(using: cloud, authorization: authorization)
                }
            }
        } message: {
            Text(stopSharingNotice)
        }
        .confirmationDialog("Remove family access?", isPresented: $isConfirmingRemoveAccess, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                performAccess { await model.removeFamilyAccess() }
            }
        } message: {
            Text("Gumbo will ask the NAS to remove the family account. Access remains until the NAS confirms removal. Existing sessions and files already downloaded may remain available.")
        }
        .confirmationDialog("Have you revoked the shared account on your NAS?", isPresented: $isConfirmingManualRevocation, titleVisibility: .visible) {
            Button("I changed or disabled it and ended its sessions") {
                performAccess { await model.acknowledgeManualFamilyRevocation(using: cloud) }
            }
        } message: {
            Text("Gumbo cannot verify this for your NAS. Confirm only after changing or disabling the shared account and ending its active sessions. This removes its saved details from Gumbo. Files already downloaded by others may remain.")
        }
        .sheet(isPresented: $isEnteringAccount) {
            FamilyAccountSheet()
        }
        .sheet(isPresented: $isJoiningWithLink) {
            JoinWithLinkSheet()
        }
    }

    /// The read-only NAS account members connect with, made by the app or entered by hand.
    private var familyAccessGroup: some View {
        SettingsGroup(title: "Family access", footer: accessFooter) {
            if let access = model.familyAccess {
                SettingsRow(symbol: "key.fill", tint: .green, title: "Family access") {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Ready, account \(access.account)")
                }
                if model.canManageNASAccounts {
                    SettingsButtonRow(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: isWorkingOnAccess ? "Working…" : "Rotate password") {
                        performAccess { await model.rotateFamilyAccess() }
                    }
                    .disabled(isWorkingOnAccess)
                    SettingsButtonRow(symbol: "key.slash", tint: .red, title: "Remove family access", role: .destructive) {
                        isConfirmingRemoveAccess = true
                    }
                    .disabled(isWorkingOnAccess)
                } else {
                    SettingsButtonRow(symbol: "person.text.rectangle", tint: .secondary, title: "Update shared account") { isEnteringAccount = true }
                        .disabled(isWorkingOnAccess)
                }
            } else {
                if model.familyAccessNeedsVerification {
                    Text("An earlier family account needs verification for this connection. Use its existing name and password below. Your previous setup is still kept.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
                if model.canManageNASAccounts {
                    SettingsButtonRow(symbol: "key.fill", tint: .green, title: isWorkingOnAccess ? "Setting up…" : "Set up family access") {
                        performAccess { await model.setUpFamilyAccess() }
                    }
                    .disabled(isWorkingOnAccess || model.familyRevocationPending)
                }
                SettingsButtonRow(symbol: "person.text.rectangle", tint: .indigo, title: "Use an existing account") {
                    isEnteringAccount = true
                }
            }
        }
    }

    private var footer: String {
        switch cloud.status {
        case .noAccount: "Sign in to iCloud in the Settings app to sync profiles across your devices and share them with your family."
        case .failed: Hints.familyRetry
        default: "Profiles, favourites, playlists and settings follow you to every device signed in with your Apple Account."
        }
    }
}

#else
/// Native preferences for iCloud, the shared NAS account, and membership.
struct FamilyView: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppModel.self) private var model
    @State private var isWorkingOnAccess = false
    @State private var isEnteringAccount = false
    @State private var isConfirmingRemoveAccess = false
    @State private var isConfirmingStop = false
    @State private var isConfirmingManualRevocation = false
    @State private var isJoiningWithLink = false
    @State private var problem: String?

    private var permissions: Permissions { Permissions(profiles: profiles, cloud: cloud) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Sync", value: cloud.status.text)
            } header: {
                Text("iCloud")
            } footer: {
                Text(footer)
            }
            if permissions.canManageFamily, model.connection?.isHomeOnly == true {
                Section {
                    Label("Home network only", systemImage: "house")
                } header: {
                    Text("Reaching the server")
                } footer: {
                    Text("Members need a route to this NAS. Tailscale is an optional way to connect remotely. When you change the server address or owner account, verify family access again for that connection.")
                }
            }
            if cloud.isActive, permissions.canManageFamily, !model.isDemo { familyAccessSection }
            if (cloud.isActive && cloud.isOwner && !cloud.isShared) || cloud.needsFamilyInvitation {
                Section {
                    Button("Join with an invitation link", systemImage: "link") { isJoiningWithLink = true }
                } header: {
                    Text(cloud.needsFamilyInvitation ? "Reconnect with your family" : "Joining someone else's family")
                } footer: {
                    Text("Invitations are icloud.com/share links made in Gumbo. Opening one on this device normally joins straight away; if it opened in a browser instead, paste it here. Any Apple Account can join, wherever it lives; Family Sharing is not needed.")
                }
            }
            if cloud.isActive || (model.familyRevocationPending && cloud.currentUserRecordName != nil) {
                if (cloud.isOwner && (cloud.isShared || model.familyRevocationPending) && permissions.canManageFamily) || (!cloud.isOwner && permissions.canLeave) {
                    Section {
                        Button(model.familyRevocationPending ? "Finish stopping sharing" : (cloud.isOwner ? "Stop sharing" : "Leave family"), role: .destructive) { isConfirmingStop = true }
                            .disabled(isWorkingOnAccess)
                        if model.familyRevocationPending && !model.canManageNASAccounts && !cloud.isShared {
                            Button("I changed the NAS account", systemImage: "checkmark.shield") { isConfirmingManualRevocation = true }
                                .disabled(isWorkingOnAccess)
                        }
                    } footer: {
                        Text(cloud.isOwner ? stopSharingNotice : "Your profile stays on this device; the family's profiles go.")
                    }
                }
            }
            if let problem {
                Section { Text(problem).font(.callout).foregroundStyle(.red) }
            }
        }
        .groupedForm()
        .navigationTitle("Family")
        .inlineTitle()
        .pullToRefresh { await cloud.refresh(reason: "pull") }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await cloud.refresh(reason: "toolbar") } }
            }
            #endif
        }
        .confirmationDialog(cloud.isOwner ? "Stop sharing the family?" : "Leave the family?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
            Button(cloud.isOwner ? "Stop sharing" : "Leave", role: .destructive) {
                guard let authorization = cloud.sharingAuthorization() else { return }
                performAccess(requiresOwner: cloud.isOwner) {
                    await model.stopFamilySharing(using: cloud, authorization: authorization)
                }
            }
        } message: {
            Text(stopSharingNotice)
        }
        .confirmationDialog("Remove family access?", isPresented: $isConfirmingRemoveAccess, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                performAccess { await model.removeFamilyAccess() }
            }
        } message: {
            Text("Gumbo will ask the NAS to remove the family account. Access remains until the NAS confirms removal. Existing sessions and files already downloaded may remain available.")
        }
        .confirmationDialog("Have you revoked the shared account on your NAS?", isPresented: $isConfirmingManualRevocation, titleVisibility: .visible) {
            Button("I changed or disabled it and ended its sessions") {
                performAccess { await model.acknowledgeManualFamilyRevocation(using: cloud) }
            }
        } message: {
            Text("Gumbo cannot verify this for your NAS. Confirm only after changing or disabling the shared account and ending its active sessions. This removes its saved details from Gumbo. Files already downloaded by others may remain.")
        }
        .sheet(isPresented: $isEnteringAccount) { FamilyAccountSheet() }
        .sheet(isPresented: $isJoiningWithLink) { JoinWithLinkSheet() }
    }

    private var familyAccessSection: some View {
        Section {
            if let access = model.familyAccess {
                LabeledContent("Account", value: access.account)
                LabeledContent("Status", value: "Ready")
                if model.canManageNASAccounts {
                    Button(isWorkingOnAccess ? "Working…" : "Rotate password", systemImage: "arrow.triangle.2.circlepath") {
                        performAccess { await model.rotateFamilyAccess() }
                    }
                    .disabled(isWorkingOnAccess)
                    Button("Remove family access", role: .destructive) { isConfirmingRemoveAccess = true }
                        .disabled(isWorkingOnAccess)
                } else {
                    Button("Update shared account", systemImage: "person.text.rectangle") { isEnteringAccount = true }
                        .disabled(isWorkingOnAccess)
                }
            } else {
                if model.familyAccessNeedsVerification {
                    Text("An earlier family account needs verification for this connection. Use its existing name and password below. Your previous setup is still kept.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if model.canManageNASAccounts {
                    Button(isWorkingOnAccess ? "Setting up…" : "Set up family access", systemImage: "key") {
                        performAccess { await model.setUpFamilyAccess() }
                    }
                    .disabled(isWorkingOnAccess || model.familyRevocationPending)
                }
                Button("Use an existing account", systemImage: "person.text.rectangle") { isEnteringAccount = true }
            }
        } header: {
            Text("Family access")
        } footer: {
            Text(accessFooter)
        }
    }

    private var footer: String {
        switch cloud.status {
        case .noAccount:
            #if os(macOS)
            "Sign in to iCloud in System Settings to sync profiles across your devices and share them with your family."
            #else
            "Sign in to iCloud in the Settings app to sync profiles across your devices and share them with your family."
            #endif
        case .failed: Hints.familyRetry
        default: "Profiles, favourites, playlists and settings follow you to every device signed in with your Apple Account."
        }
    }
}

#endif

struct ShareItem: Identifiable {
    let id = UUID()
    let share: CKShare
}

/// One step of a DSM walkthrough.
struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Palette.onInk)
                .frame(width: 24, height: 24)
                .background(Palette.ink, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

#if os(tvOS)
/// An account the owner made in DSM by hand, checked with a sign-in before it is kept.
private struct FamilyAccountSheet: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var isChecking = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    SettingsGroup(title: model.canManageNASAccounts ? "In DSM" : "In your NAS settings", footer: FamilyAccountGuidance.footer) {
                        ForEach(Array(FamilyAccountGuidance.instructions(for: model.connection?.providerKind ?? .synology).enumerated()), id: \.offset) { index, instruction in
                            InstructionRow(number: index + 1, text: instruction)
                        }
                    }
                    SettingsGroup(footer: "Gumbo checks the account by signing in once, then shares it with your family through iCloud, encrypted, so nobody has to type it.") {
                        HStack(spacing: 14) {
                            SettingsIcon(symbol: "person.fill", tint: .indigo)
                            TextField("Account", text: $account)
                                .noAutocapitalization()
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        HStack(spacing: 14) {
                            SettingsIcon(symbol: "key.fill", tint: .green)
                            SecureField("Password", text: $password)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    if let problem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(Palette.paper)
            .navigationTitle("Family Account")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isChecking ? "Checking…" : "Use") {
                        guard let session = profiles.sessionID, profiles.canManageProfiles else { return }
                        let connection = model.connection
                        Task {
                            guard profiles.sessionID == session, profiles.canManageProfiles, model.connection == connection else { return }
                            isChecking = true
                            problem = await model.useFamilyAccess(account: account.trimmingCharacters(in: .whitespaces), password: password)
                            isChecking = false
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isChecking)
                }
            }
        }
    }
}

#else
/// A separate NAS account, verified before Gumbo stores or shares its credentials.
private struct FamilyAccountSheet: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var isChecking = false
    @State private var problem: String?

    private var instructions: [String] {
        FamilyAccountGuidance.instructions(for: model.connection?.providerKind ?? .synology)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .top) {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(instruction).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    Text(model.canManageNASAccounts ? "In DSM" : "In your NAS settings")
                } footer: {
                    Text(FamilyAccountGuidance.footer)
                }
                Section {
                    TextField("Account", text: $account)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } header: {
                    Text("NAS account")
                } footer: {
                    Text("Gumbo checks the account by signing in once, then shares the chosen credentials with your family through iCloud. The password is stored in an encrypted CloudKit field.")
                }
                if let problem {
                    Section { Text(problem).font(.callout).foregroundStyle(.red) }
                }
            }
            .groupedForm()
            .navigationTitle("Family Account")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isChecking ? "Checking…" : "Use") {
                        guard let session = profiles.sessionID, profiles.canManageProfiles else { return }
                        let connection = model.connection
                        Task {
                            guard profiles.sessionID == session, profiles.canManageProfiles, model.connection == connection else { return }
                            isChecking = true
                            problem = await model.useFamilyAccess(account: account.trimmingCharacters(in: .whitespaces), password: password)
                            isChecking = false
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isChecking)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 480, idealHeight: 580)
        #endif
    }
}
#endif

private extension FamilyView {
    var accessFooter: String {
        if !model.canManageNASAccounts {
            return "Create a separate account in your NAS settings with read-only access to the music folder and permission to use this connection. Gumbo shares its credentials through iCloud with invited family members. Manage its password and permissions on the NAS; changing shared details here does not revoke existing NAS access."
        }
        return model.familyAccess == nil
            ? "Use a separate read-only NAS account for the family. Gumbo can create one on a NAS that allows it, or you can enter an existing account. Its credentials are shared through iCloud with people who join using your invitation link."
            : "Family members connect with this shared account. Rotate its password to revoke saved credentials; existing NAS sessions and downloaded files may remain available."
    }

    var stopSharingNotice: String {
        if cloud.isOwner, !model.canManageNASAccounts {
            return "iCloud sharing will stop. To revoke NAS access, also change or disable the shared account and end its existing sessions in your NAS settings. Previously downloaded files may remain available."
        }
        return cloud.isOwner
            ? "Invited members lose access to the family’s profiles. Gumbo will try to rotate the shared NAS password; existing sessions and downloaded files may remain available."
            : "Your profile stays on this device; the family’s profiles go."
    }

    func performAccess(requiresOwner: Bool = true, _ operation: @escaping @MainActor () async -> String?) {
        guard let session = profiles.sessionID,
              !requiresOwner || permissions.canManageFamily else { return }
        let connection = model.connection
        Task {
            guard profiles.sessionID == session, model.connection == connection,
                  !requiresOwner || permissions.canManageFamily else { return }
            isWorkingOnAccess = true
            problem = await operation()
            isWorkingOnAccess = false
        }
    }
}

private enum FamilyAccountGuidance {
    static let footer = "If you already have a family account, check its read-only permissions and enter it below. Otherwise, create a separate account in your NAS administration first. Gumbo verifies access but cannot verify every server-side permission."

    static func instructions(for kind: NASProviderKind) -> [String] {
        if kind == .synology {
            return [
                "Go to Control Panel, then User & Group, and select Create.",
                "Name it gumbo-family and give it a password. This one account is shared by your family.",
                "Give it Read only on your music folder and no access to everything else.",
                "Allow File Station and deny other applications.",
                "Finish, then enter the name and password below."
            ]
        }
        return [
            "Open your NAS administration and create a separate account for your family.",
            "Allow it to read your selected music folder or share, and deny writes, deletion and access to unrelated files.",
            "Allow this account to use \(kind == .webDAV ? "WebDAV over HTTPS" : "the selected SMB share") with the same connection settings you use in Gumbo.",
            "Enter that account’s name and password below. Update them here whenever you change the password on the NAS."
        ]
    }
}

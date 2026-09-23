#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
#endif
import CloudKit
import GumboCore
import SwiftUI

/// Name, photo and lock of a profile; new ones are made here too.
struct ProfileEditorSheet: View {
    @State private var profile: Profile?
    @Environment(ProfileStore.self) private var profiles
    @Environment(CloudSync.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var avatar: ProfileAvatar
    @State private var pinChange: PINChange = .keep
    @State private var photoChange: PhotoChange = .keep
    #if canImport(PhotosUI) && !os(tvOS)
    @State private var pickedItem: PhotosPickerItem?
    @State private var isChoosingPhoto = false
    #endif
    @State private var photoTask: Task<Void, Never>?
    @State private var isLoadingPhoto = false
    @State private var photoProblem: String?
    @State private var preview: CGImage?
    @State private var biometrics: Bool
    @State private var isSettingPIN = false
    @State private var isConfirmingDelete = false
    @State private var isVerifyingPINForChange = false
    @State private var isVerifyingPINForRemoval = false
    @State private var isVerifyingPINForBiometrics = false
    @State private var currentPINVerified = false
    @State private var problem: String?
    @State private var openingSession: UUID?

    private enum PINChange { case keep, set(String), remove }
    private enum PhotoChange {
        case keep, set(Data), remove

        var isRemove: Bool {
            if case .remove = self { return true }
            return false
        }
    }

    init(profile: Profile?) {
        _profile = State(initialValue: profile)
        _name = State(initialValue: profile?.name ?? "")
        _avatar = State(initialValue: profile?.avatar ?? ProfileAvatar.random())
        _biometrics = State(initialValue: false)
    }

    /// What the avatar shows while editing: the picked picture, the saved one, or initials.
    private var draft: Profile {
        Profile(
            id: profile?.id ?? "new", name: name.isEmpty ? "?" : name,
            avatar: photoChange.isRemove ? ProfileAvatar(symbol: avatar.symbol, colorHex: avatar.colorHex) : avatar,
            pin: nil, role: .member, createdAt: .now, updatedAt: .now
        )
    }

    private var hasPhoto: Bool {
        switch photoChange {
        case .keep: avatar.hasPhoto
        case .set: true
        case .remove: false
        }
    }

    private var hasPIN: Bool {
        switch pinChange {
        case .keep: profile?.isLocked ?? false
        case .set: true
        case .remove: false
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isCurrentDraft && !isLoadingPhoto
    }

    private var isCurrentDraft: Bool {
        guard let openingSession, profiles.sessionID == openingSession else { return false }
        return profile.map { profiles.canEditDraft($0, session: openingSession) } ?? profiles.canManageProfiles
    }

    /// Changing or removing the PIN on YOUR OWN profile (the currently active profile) requires
    /// verifying the current PIN first to prevent someone else from disabling your lock while you're away.
    private var requiresPINVerification: Bool {
        guard let profile, profile.isLocked, !currentPINVerified else { return false }
        return profile.id == profiles.activeID
    }

    /// Turning biometric unlock on for a PIN-locked profile needs the PIN too, or anyone
    /// whose finger or face is enrolled on this device could let themselves in later.
    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { biometrics },
            set: { enabled in
                if enabled && !biometrics && requiresPINVerification {
                    isVerifyingPINForBiometrics = true
                } else {
                    biometrics = enabled
                }
            }
        )
    }

    private func validateDraft() -> Bool {
        guard isCurrentDraft else {
            problem = "This profile or session changed. Close this editor and open it again."
            return false
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                #if os(tvOS)
                ScrollView {
                    VStack(spacing: 28) {
                        VStack(spacing: 14) {
                            ProfileAvatarView(profile: draft, size: 124, isLocked: hasPIN, preview: photoChange.isRemove ? nil : preview)
                                .animation(.snappy(duration: 0.25), value: preview.map(ObjectIdentifier.init))
                            Text("Change the photo from your iPhone or Mac.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)

                        SettingsGroup {
                            HStack(spacing: 14) {
                                SettingsIcon(symbol: "person.fill", tint: Color(hex: avatar.colorHex))
                                TextField("Name", text: $name)
                                    .wordsAutocapitalization()
                                    .submitLabel(.done)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        SettingsGroup(title: "Lock", footer: hasPIN ? "The PIN is asked for before this profile opens on any device." : "Without a PIN anyone using this device can open the profile.") {
                            if hasPIN {
                                SettingsRow(symbol: "lock.fill", tint: .orange, title: "PIN") {
                                    Text("••••")
                                        .foregroundStyle(.secondary)
                                }
                                SettingsButtonRow(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: "Change PIN") {
                                    if requiresPINVerification { isVerifyingPINForChange = true }
                                    else { isSettingPIN = true }
                                }
                                SettingsButtonRow(symbol: "lock.open", tint: .red, title: "Remove PIN", role: .destructive) {
                                    if requiresPINVerification { isVerifyingPINForRemoval = true }
                                    else {
                                        pinChange = .remove
                                        biometrics = false
                                    }
                                }
                                if let biometry = profiles.biometryName {
                                    SettingsRow(symbol: biometry == "Face ID" ? "faceid" : "touchid", tint: .green, title: "Open with \(biometry)") {
                                        Toggle("Open with \(biometry)", isOn: biometricsBinding)
                                            .labelsHidden()
                                    }
                                }
                            } else {
                                SettingsButtonRow(symbol: "lock.fill", tint: .orange, title: "Set a PIN") { isSettingPIN = true }
                            }
                        }

                        if let profile, cloud.isActive, let user = cloud.currentUserRecordName {
                            SettingsGroup(title: "iCloud", footer: profile.userRecordName == user ? "Opens on its own on every device signed in with your Apple Account." : "Makes this the profile your own devices open first.") {
                                if profile.userRecordName == user {
                                    SettingsRow(symbol: "icloud.fill", tint: .blue, title: "This is you") { EmptyView() }
                                } else {
                                    SettingsButtonRow(symbol: "icloud.fill", tint: .blue, title: "Use on my Apple Account") {
                                        guard validateDraft() else { return }
                                        if profiles.bindToCurrentUser(profile) { dismiss() }
                                        else { problem = "Open your profile before making changes." }
                                    }
                                }
                            }
                        }

                        if let profile, profiles.profiles.count > 1, Permissions(profiles: profiles, cloud: cloud).canManageProfiles {
                            SettingsGroup {
                                SettingsButtonRow(symbol: "trash", tint: .red, title: "Delete Profile", role: .destructive) { isConfirmingDelete = true }
                            }
                            .confirmationDialog("Delete “\(profile.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                                Button("Delete Profile", role: .destructive) {
                                    guard validateDraft() else { return }
                                    if profiles.delete(profile) { dismiss() }
                                    else { problem = "Open the owner's profile to delete a profile." }
                                }
                            } message: {
                                Text("Its favourites, playlists and history on this device go with it.")
                            }
                        }
                        if let problem {
                            Text(problem)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .background(Palette.paper)
                #else
                Form {
                    Section {
                        photoEditor
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        TextField("Name", text: $name)
                            .wordsAutocapitalization()
                            .submitLabel(.done)
                            .accessibilityIdentifier("profile.name")
                    } header: {
                        Text("Name")
                    }
                    Section {
                        if hasPIN {
                            LabeledContent("PIN", value: "Set")
                            Button("Change PIN", systemImage: "arrow.triangle.2.circlepath") {
                                if requiresPINVerification { isVerifyingPINForChange = true }
                                else { isSettingPIN = true }
                            }
                            Button("Remove PIN", systemImage: "lock.open", role: .destructive) {
                                if requiresPINVerification { isVerifyingPINForRemoval = true }
                                else {
                                    pinChange = .remove
                                    biometrics = false
                                }
                            }
                            if let biometry = profiles.biometryName {
                                Toggle("Open with \(biometry)", isOn: biometricsBinding)
                            }
                        } else {
                            Button("Set a PIN", systemImage: "lock") { isSettingPIN = true }
                        }
                    } header: {
                        Text("Lock")
                    } footer: {
                        Text(hasPIN ? "The PIN is asked for before this profile opens on any device." : "Without a PIN anyone using this device can open the profile.")
                    }
                    if let profile, cloud.isActive, let user = cloud.currentUserRecordName {
                        Section {
                            if profile.userRecordName == user {
                                Label("This is you", systemImage: "icloud")
                            } else {
                                Button("Use on my Apple Account", systemImage: "icloud") {
                                    guard validateDraft() else { return }
                                    if profiles.bindToCurrentUser(profile) { dismiss() }
                                    else { problem = "Open your profile before making changes." }
                                }
                            }
                        } header: {
                            Text("iCloud")
                        } footer: {
                            Text(profile.userRecordName == user ? "Opens on its own on every device signed in with your Apple Account." : "Makes this the profile your own devices open first.")
                        }
                    }
                    if let profile, profiles.profiles.count > 1, Permissions(profiles: profiles, cloud: cloud).canManageProfiles {
                        Section {
                            Button("Delete Profile", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                        }
                        .confirmationDialog("Delete “\(profile.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                            Button("Delete Profile", role: .destructive) {
                                guard validateDraft() else { return }
                                if profiles.delete(profile) { dismiss() }
                                else { problem = "Open the owner's profile to delete a profile." }
                            }
                        } message: {
                            Text("Its favourites, playlists and history on this device go with it.")
                        }
                    }
                    if let problem {
                        Section { Text(problem).font(.callout).foregroundStyle(.red) }
                    }
                }
                .groupedForm()
                #endif
            }
            .navigationTitle(profile == nil ? "New Profile" : "Edit Profile")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("profile.save")
                }
            }
            .onAppear {
                if openingSession == nil { openingSession = profiles.sessionID }
                if let profile { biometrics = profiles.biometricsEnabled(for: profile) }
            }
            #if canImport(PhotosUI) && !os(tvOS)
            .onChange(of: pickedItem) { _, item in
                loadPhoto(item)
            }
            #endif
            .onDisappear { photoTask?.cancel() }
            .onChange(of: profiles.sessionID) { _, _ in
                photoTask?.cancel()
                dismiss()
            }
            .sheet(isPresented: $isSettingPIN) {
                PINSetupSheet { pin in pinChange = .set(pin) }
            }
            .sheet(isPresented: $isVerifyingPINForChange) {
                PINVerificationSheet(profile: profile!) { verified in
                    if verified {
                        currentPINVerified = true
                        isSettingPIN = true
                    }
                }
            }
            .sheet(isPresented: $isVerifyingPINForRemoval) {
                PINVerificationSheet(profile: profile!) { verified in
                    if verified {
                        currentPINVerified = true
                        pinChange = .remove
                        biometrics = false
                    }
                }
            }
            .sheet(isPresented: $isVerifyingPINForBiometrics) {
                PINVerificationSheet(profile: profile!) { verified in
                    if verified {
                        currentPINVerified = true
                        biometrics = true
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 440, idealHeight: 540)
        #endif
    }

    #if !os(tvOS)
    private var photoEditor: some View {
        VStack(spacing: 12) {
            #if canImport(PhotosUI)
            Menu {
                Button("Choose Photo", systemImage: "photo.on.rectangle") {
                    // Reselecting the same image must retry a failed transfer too.
                    pickedItem = nil
                    isChoosingPhoto = true
                }
                if hasPhoto {
                    Button("Remove Photo", systemImage: "trash", role: .destructive) {
                        photoTask?.cancel()
                        pickedItem = nil
                        isLoadingPhoto = false
                        photoProblem = nil
                        photoChange = .remove
                        preview = nil
                    }
                }
            } label: {
                VStack(spacing: 10) {
                    ProfileAvatarView(profile: draft, size: 104, preview: photoChange.isRemove ? nil : preview)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 34, height: 34)
                                .background(.regularMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
                                .accessibilityHidden(true)
                        }
                    Text(hasPhoto ? "Edit Photo" : "Add Photo")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(hasPhoto ? "Edit Profile Photo" : "Add Profile Photo")
            .accessibilityIdentifier("profile.photo")
            .photosPicker(isPresented: $isChoosingPhoto, selection: $pickedItem, matching: .images)
            #else
            ProfileAvatarView(profile: draft, size: 104)
            #endif
            if isLoadingPhoto {
                ProgressView("Loading Photo…").font(.footnote)
            }
            if let photoProblem {
                Text(photoProblem).font(.footnote).foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
    #endif

    #if canImport(PhotosUI) && !os(tvOS)
    private func loadPhoto(_ item: PhotosPickerItem?) {
        photoTask?.cancel()
        photoProblem = nil
        guard let item else { isLoadingPhoto = false; return }
        isLoadingPhoto = true
        photoTask = Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Task.checkCancellation()
                let image = await Task.detached(priority: .userInitiated) {
                    PlatformImages.cgImage(data: data, maxPixelSize: 640)
                }.value
                try Task.checkCancellation()
                guard isCurrentDraft else {
                    photoProblem = "This profile changed. Close the editor and open it again."
                    isLoadingPhoto = false
                    return
                }
                guard let image else { throw CocoaError(.fileReadCorruptFile) }
                photoChange = .set(data)
                preview = image
                isLoadingPhoto = false
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingPhoto = false
                photoProblem = "This photo couldn't be loaded. Try choosing it again or pick another photo."
            }
        }
    }
    #endif

    private func save() {
        guard validateDraft() else { return }
        guard canSave else {
            problem = "Open your profile before saving changes."
            return
        }
        let newPIN: String? = if case .set(let pin) = pinChange { pin } else { nil }
        var saved: Profile?
        if let profile {
            guard var updated = profiles.profiles.first(where: { $0.id == profile.id }) else {
                problem = "This profile is no longer available."
                return
            }
            updated.name = name
            updated.avatar = avatar
            switch pinChange {
            case .keep: break
            case .set(let pin): updated.pin = PINRecord.make(pin)
            case .remove: updated.pin = nil
            }
            guard profiles.update(updated) else {
                problem = "This profile changed. Open it again to save your changes."
                return
            }
            profiles.setBiometrics(biometrics && updated.isLocked, for: updated)
            saved = profiles.profiles.first { $0.id == profile.id }
        } else if let created = profiles.create(name: name, avatar: avatar, pin: newPIN) {
            profiles.setBiometrics(biometrics && created.isLocked, for: created)
            saved = created
        }
        guard let saved else {
            problem = "The profile could not be saved."
            return
        }
        // The name and lock are already saved. Keep the new baseline if the photo fails so
        // retry is still authorized and a newly created profile is not created a second time.
        profile = saved
        pinChange = .keep
        let photoSaved: Bool
        switch photoChange {
        case .keep: photoSaved = true
        case .set(let data): photoSaved = profiles.setPhoto(data, for: saved)
        case .remove: photoSaved = profiles.setPhoto(nil, for: saved)
        }
        guard photoSaved else {
            photoProblem = "Your profile details were saved, but the photo couldn't be updated. Try saving again."
            return
        }
        dismiss()
    }
}


/// Settings page listing every profile on this device.
struct ManageProfilesView: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(PlayerModel.self) private var player
    @Environment(CloudSync.self) private var cloud
    @State private var editing: ProfileEditorTarget?
    @State private var share: ShareItem?
    @State private var isPreparingShare = false
    @State private var problem: String?

    private var permissions: Permissions { Permissions(profiles: profiles, cloud: cloud) }

    var body: some View {
        Group {
            #if os(tvOS)
            ScrollView {
                VStack(spacing: 28) {
                    SettingsGroup(footer: footer) {
                        ForEach(profiles.profiles) { profile in
                            Button {
                                editing = .existing(profile)
                            } label: {
                                HStack(spacing: 14) {
                                    ProfileAvatarView(profile: profile, size: 44, isLocked: profile.isLocked)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.body.weight(.medium))
                                        Text(profile.role == .owner ? "Owner" : "Member")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if profile.id == profiles.activeID {
                                        Text("Now")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    if permissions.canEdit(profile, profiles: profiles) {
                                        DisclosureChevron()
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowPressStyle())
                            .disabled(!permissions.canEdit(profile, profiles: profiles))
                        }
                        // People who have an invitation but have not opened it yet.
                        ForEach(cloud.participants.filter { !$0.accepted }) { participant in
                            SettingsRow(symbol: "person.badge.clock", tint: .gray, title: participant.name, subtitle: "Invited, not joined yet") {
                                EmptyView()
                            }
                        }
                        if cloud.isActive, permissions.canManageFamily {
                            SettingsButtonRow(symbol: "person.badge.plus", tint: .blue, title: isPreparingShare ? "Preparing…" : "Invite someone") {
                                invite()
                            }
                            .disabled(isPreparingShare)
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
            #else
            List {
                Section {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            editing = .existing(profile)
                        } label: {
                            HStack {
                                ProfileAvatarView(profile: profile, size: 44, isLocked: profile.isLocked)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).font(.body.weight(.medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text((profile.role == .owner ? "Owner" : "Member") + (profile.id == profiles.activeID ? " · Current Profile" : ""))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if permissions.canEdit(profile, profiles: profiles) {
                                    Image(systemName: "pencil")
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!permissions.canEdit(profile, profiles: profiles))
                        .accessibilityHint(permissions.canEdit(profile, profiles: profiles) ? "Edit this profile." : "Only the profile or family owner can edit it.")
                    }
                    ForEach(cloud.participants.filter { !$0.accepted }) { participant in
                        Label {
                            VStack(alignment: .leading) {
                                Text(participant.name)
                                Text("Invited, not joined yet").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.badge.clock").foregroundStyle(.secondary)
                        }
                    }
                    if cloud.isActive, permissions.canManageFamily {
                        Button(isPreparingShare ? "Preparing…" : "Invite someone", systemImage: "person.badge.plus") { invite() }
                            .disabled(isPreparingShare)
                    }
                } footer: {
                    Text(footer)
                }
                if let problem {
                    Section { Text(problem).font(.callout).foregroundStyle(.red) }
                }
            }
            .groupedList()
            #endif
        }
        .navigationTitle("Profiles")
        .inlineTitle()
        .sheet(item: $editing) { target in
            ProfileEditorSheet(profile: target.profile)
        }
        .sheet(item: $share, onDismiss: { Task { await cloud.refresh(reason: "invite sheet closed") } }) { item in
            InviteSheet(share: item.share)
        }
    }

    private var footer: String {
        guard permissions.canManageProfiles else { return "You can change your own profile. The family's owner manages the others." }
        let everyone = "Everyone who joins appears here with their own favourites, playlists, history, downloads and settings."
        #if os(macOS)
        return cloud.isActive ? "Up to five people can join. " + everyone : "Sign in to iCloud in System Settings to invite your family. " + everyone
        #else
        return cloud.isActive ? "Up to five people can join. " + everyone : "Sign in to iCloud in the Settings app to invite your family. " + everyone
        #endif
    }

    /// The owner's invitation link, through the system share sheet.
    private func invite() {
        guard let authorization = cloud.sharingAuthorization() else { return }
        isPreparingShare = true
        problem = nil
        Task {
            do {
                share = ShareItem(share: try await cloud.share(authorization: authorization))
            } catch {
                problem = error.localizedDescription
            }
            isPreparingShare = false
        }
    }
}

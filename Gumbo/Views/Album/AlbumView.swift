import GumboCore
import SwiftUI

/// A retained row or confirmation can outlive the library or authenticated profile that opened it.
private struct AlbumActionScope: Equatable {
    let sourceID: String
    let rootPath: String
    let profileID: String?
    let sessionID: UUID?

    init(library: LibraryStore, profiles: ProfileStore) {
        sourceID = library.catalogue.driveID
        rootPath = library.catalogue.rootPath
        profileID = profiles.activeID
        sessionID = profiles.sessionID
    }

    func isCurrent(library: LibraryStore, profiles: ProfileStore) -> Bool {
        profileID != nil && sessionID != nil && library.contentSourceID == sourceID
            && self == AlbumActionScope(library: library, profiles: profiles)
    }
}

private struct AlbumRemovalRequest {
    let album: Album
    let owner: DownloadOwner
    let scope: AlbumActionScope
}

private struct AlbumDeletionPresentation: Identifiable {
    let id = UUID()
    let album: Album
    let scope: AlbumActionScope
}

struct AlbumView: View {
    let album: Album
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProfileStore.self) private var profiles
    @Environment(CloudSync.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFlipped = false
    @State private var isConfirmingRemoval = false
    @State private var removalRequest: AlbumRemovalRequest?
    @State private var isRenaming = false
    @State private var deletionPresentation: AlbumDeletionPresentation?
    @State private var shouldCloseAfterDeletion = false
    /// The album's id once a rename gave it a new one; the page follows the album rather than the old id.
    @State private var renamedID: String?
    /// A new id whose album is still being derived after a rename.
    @State private var pendingID: String?

    private var currentID: String { renamedID ?? album.id }
    private var permissions: Permissions { Permissions(profiles: profiles, cloud: cloud) }

    var body: some View {
        Group {
            if let current = library.album(id: currentID) {
                albumContent(current)
            } else if pendingID != nil {
                ProgressView("Updating album…")
                    .inlineTitle()
                    .windowTitle(album.title)
            } else {
                ContentUnavailableView("Album Unavailable", systemImage: "square.stack", description: Text("This album is no longer in the current library."))
                    .inlineTitle()
                    .windowTitle("Album Unavailable")
            }
        }
        #if !os(tvOS)
        // Keep the operation sheet alive when deleting the last song removes albumContent.
        .sheet(item: $deletionPresentation, onDismiss: {
            if shouldCloseAfterDeletion {
                shouldCloseAfterDeletion = false
                dismiss()
            }
        }) { presentation in
            AlbumDeletionSheet(presentation: presentation) { removedAlbum in
                shouldCloseAfterDeletion = removedAlbum
            }
            .id(presentation.id)
        }
        #endif
        .onChange(of: library.contentRevision) { _, _ in
            guard let pending = pendingID, library.album(id: pending) != nil else { return }
            renamedID = pending
            pendingID = nil
        }
    }

    /// The rename wrote a new title: follow the album to its new id as soon as the library shows it.
    private func follow(albumID: String) {
        guard albumID != currentID else { return }
        if library.album(id: albumID) != nil {
            renamedID = albumID
        } else {
            pendingID = albumID
        }
    }

    private func albumContent(_ album: Album) -> some View {
        let scope = AlbumActionScope(library: library, profiles: profiles)
        return ScrollView {
            VStack(spacing: 0) {
                DetailHeader(coverSize: 260) {
                    // Tap the cover to turn it over; the back carries the year, genre and quality.
                    FlipView(angle: isFlipped ? 180 : 0) {
                        ArtworkView(album: album, cornerRadius: 14, size: .hero)
                    } back: {
                        CoverBack(album: album)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 28, y: 18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.7, bounce: 0.18)) { isFlipped.toggle() }
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: isFlipped)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(isFlipped ? "Album details. Show cover" : "Album cover. Show details")
                } titles: {
                    Text(album.title)
                        .font(Fonts.pageTitle)
                    if let artist = library.artist(named: album.artist) {
                        NavigationLink(value: artist) {
                            Text(album.artist)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(album.artist)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    QualityBars(quality: album.quality)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(album.qualityLabel)
                        .padding(.top, 5)
                } actions: {
                    HStack(spacing: 10) {
                        PlayActions(playbackState: player.playbackState(for: album.tracks, sourceID: library.catalogue.driveID)) {
                            guard scope.isCurrent(library: library, profiles: profiles), library.album(id: album.id) == album else { return }
                            player.togglePlayback(of: album.tracks, sourceID: library.catalogue.driveID)
                        } shuffle: {
                            guard scope.isCurrent(library: library, profiles: profiles), library.album(id: album.id) == album else { return }
                            player.play(queue: album.tracks.shuffled(), startingAt: 0, title: album.title)
                        }
                        #if !os(tvOS)
                        downloadButton(for: album)
                        #endif
                    }
                }

                if album.hasMultipleDiscs {
                    ForEach(album.discs) { disc in
                        discHeader(disc)
                            .padding(.top, 26)
                        TrackList(album: album, tracks: disc.tracks)
                            .padding(.top, 6)
                    }
                } else {
                    TrackList(album: album, tracks: album.tracks)
                        .padding(.top, 18)
                }

                Text(footerText(for: album))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .gumboBackground(album.primaryColor)
        .inlineTitle()
        .windowTitle(album.title, subtitle: album.artist)
        #if !os(tvOS)
        .toolbar {
            if !library.isDemo {
                ToolbarItem(placement: .trailingBar) {
                    Menu {
                        Button("Rename Album…", systemImage: "pencil") { isRenaming = true }
                        if permissions.isHost {
                            Divider()
                            Button("Delete Album…", systemImage: "trash", role: .destructive) {
                                guard scope.isCurrent(library: library, profiles: profiles),
                                      permissions.isHost, library.canDeleteAlbums,
                                      library.album(id: album.id) == album else { return }
                                shouldCloseAfterDeletion = false
                                deletionPresentation = AlbumDeletionPresentation(album: album, scope: scope)
                            }
                            .disabled(!library.canDeleteAlbums)
                            .accessibilityIdentifier("album.deleteFromNAS")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .sheet(isPresented: $isRenaming) {
            AlbumRenameSheet(album: album) { albumID in follow(albumID: albumID) }
        }
        #endif
    }

    private func discHeader(_ disc: Disc) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Disc \(disc.number)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
            Spacer()
            Text("\(disc.tracks.count) \(disc.tracks.count == 1 ? "song" : "songs") · \(TimeText.long(disc.duration))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    private func footerText(for album: Album) -> String {
        var parts: [String] = []
        if album.hasMultipleDiscs { parts.append("\(album.discs.count) discs") }
        parts.append("\(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs")")
        parts.append(TimeText.long(album.duration))
        parts.append(album.sizeText)
        return parts.joined(separator: " · ")
    }

    private func downloadButton(for album: Album) -> some View {
        let owner = downloads.owner(for: album)
        let scope = AlbumActionScope(library: library, profiles: profiles)
        return DownloadStateReader(owner: owner) { state in
            if let state {
                DownloadButton(state: state) {
                    guard scope.isCurrent(library: library, profiles: profiles),
                          library.album(id: album.id) == album, downloads.owner(for: album) == owner else { return }
                    switch state {
                    case .none, .failed, .partial, .cancelled:
                        downloads.download(owner, driveID: scope.sourceID, isSample: library.isDemo) {
                            track in
                            library.streamURL(for: track, quality: .original)
                        }
                    case .downloading:
                        downloads.cancel(owner)
                    case .downloaded:
                        removalRequest = AlbumRemovalRequest(album: album, owner: owner, scope: scope)
                        isConfirmingRemoval = true
                    }
                }
            } else {
                ProgressView().frame(width: 50, height: 50).accessibilityLabel("Checking downloads")
            }
        }
        .confirmationDialog(
            "Remove this album from your \(Device.noun)?", isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                guard let request = removalRequest else { return }
                removalRequest = nil
                guard request.scope.isCurrent(library: library, profiles: profiles),
                      library.album(id: request.album.id) == request.album,
                      downloads.owner(for: request.album) == request.owner else { return }
                downloads.remove(request.owner)
            }
        } message: {
            Text("The songs stay on your server; copies a downloaded playlist still needs are kept.")
        }
    }


}

#if !os(tvOS)
/// A read-only review precedes the destructive action. Keeping the request in this sheet binds
/// confirmation to the exact files checked for this album, server and unlocked host profile.
private struct AlbumDeletionSheet: View {
    let presentation: AlbumDeletionPresentation
    let onFinished: (Bool) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(ProfileStore.self) private var profiles
    @Environment(CloudSync.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var request: AlbumDeletionRequest?
    @State private var report: AlbumDeletionReport?
    @State private var preparationError: String?
    @State private var isPreparing = false
    @State private var isDeleting = false
    @State private var isStopping = false
    @State private var job: Task<Void, Never>?
    @State private var isPresentationActive = true

    private var scope: AlbumActionScope { AlbumActionScope(library: library, profiles: profiles) }
    private var isHost: Bool { Permissions(profiles: profiles, cloud: cloud).isHost }
    private var isCurrent: Bool { isPresentationActive && isHost && presentation.scope.isCurrent(library: library, profiles: profiles) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ArtworkView(album: presentation.album, cornerRadius: 8, size: .row)
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(presentation.album.title)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(presentation.album.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if isDeleting {
                    deletionProgress
                } else if let report {
                    resultSections(report)
                } else if isPreparing {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small).tint(Palette.accent)
                            Text("Checking album files…")
                        }
                    } footer: {
                        Text("Nothing will be deleted until you confirm.")
                    }
                } else if let preparationError {
                    Section {
                        Label("Couldn’t prepare this album", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(preparationError)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again", action: prepare)
                            .disabled(!isCurrent || !library.canDeleteAlbums)
                    } footer: {
                        Text("No files have been deleted.")
                    }
                } else if let request {
                    reviewSections(request)
                }
            }
            .groupedForm()
            .navigationTitle(report == nil ? "Delete Album" : "Deletion Results")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isDeleting, report == nil {
                        Button("Cancel") { endPresentationWork(); dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if report != nil {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .sheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isDeleting)
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 440)
        #endif
        .onAppear { if request == nil, report == nil, preparationError == nil { prepare() } }
        .onChange(of: scope) { _, _ in
            guard !isCurrent else { return }
            endPresentationWork()
            dismiss()
        }
        .onChange(of: isHost) { _, host in
            guard !host else { return }
            endPresentationWork()
            dismiss()
        }
        .onDisappear(perform: endPresentationWork)
    }

    @ViewBuilder private func reviewSections(_ request: AlbumDeletionRequest) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Permanently delete \(request.fileCount) \(request.fileCount == 1 ? "music file" : "music files") from your NAS?")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This removes the original songs for everyone who uses this library. Gumbo cannot undo this.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Other devices remove the songs and downloaded copies after a successful library refresh. Apple Watch updates when it syncs with iPhone. Offline devices update after reconnecting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Delete from NAS", role: .destructive) { delete(request) }
                    .foregroundStyle(.red)
                    .disabled(!isCurrent || !library.canDeleteAlbum(using: request))
                    .accessibilityIdentifier("album.confirmDeleteFromNAS")
                    .accessibilityLabel("Permanently delete \(request.fileCount) files from \(request.albumTitle) on the NAS")
                    .accessibilityHint("Deletes the original music files for everyone using this library. Gumbo cannot undo this.")
                if !library.canDeleteAlbums {
                    Text("Connect to your NAS and wait for other library changes to finish before deleting.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !library.canDeleteAlbum(using: request) {
                    Text("This album or connection changed. Close this review and open the album again to check its current files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        Section {
            DisclosureGroup("Review \(request.fileCount) \(request.fileCount == 1 ? "File" : "Files")") {
                ForEach(request.tracks) { track in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .fixedSize(horizontal: false, vertical: true)
                        if let path = track.path {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .selectableText()
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } footer: {
            Text("Only these music files are selected. Album folders, cover images and other files are kept.")
                .font(.footnote)
                .fontWeight(.regular)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deletionProgress: some View {
        Section {
            let progress = library.albumDeletionProgress
            OperationProgressView(
                title: "Deleting from NAS",
                currentItem: progress?.title,
                fractionCompleted: progress.flatMap { $0.total > 0 ? Double($0.completed) / Double($0.total) : nil },
                counter: progress.map { "\($0.completed) of \($0.total) files" },
                isStopping: isStopping,
                onStop: stop
            )
        } footer: {
            Text("Stopping finishes the current file. Files already deleted stay deleted.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func resultSections(_ report: AlbumDeletionReport) -> some View {
        Section {
            Label(resultTitle(report), systemImage: report.remainingCount == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.headline)
            Text("Deleted \(report.deleted.count) \(report.deleted.count == 1 ? "file" : "files") from the NAS.")
                .fixedSize(horizontal: false, vertical: true)
            if report.remainingCount > 0 {
                Text("Deletion wasn’t confirmed for \(report.remainingCount) \(report.remainingCount == 1 ? "file" : "files"). Refresh the album before retrying.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let persistenceError = report.persistenceError {
            Section {
                Label("Library Refresh Needed", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(persistenceError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !report.failures.isEmpty {
            Section("Deletion Not Confirmed") {
                ForEach(report.failures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.title)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(failure.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func resultTitle(_ report: AlbumDeletionReport) -> String {
        if report.remainingCount == 0 { return "Album Deleted" }
        if report.wasCancelled { return "Deletion Stopped" }
        return report.deleted.isEmpty ? "Deletion Not Confirmed" : "Some Files Deleted"
    }

    private func prepare() {
        guard !isPreparing, !isDeleting else { return }
        guard isCurrent else {
            preparationError = "Your library or profile changed. Close this review and open the album again."
            return
        }
        guard library.canDeleteAlbums else {
            preparationError = "Connect as the library owner and wait for the library to finish updating, then try again."
            return
        }
        isPreparing = true
        preparationError = nil
        job = Task { @MainActor in
            defer { isPreparing = false; job = nil }
            do {
                let prepared = try await library.prepareAlbumDeletion(presentation.album)
                guard !Task.isCancelled, isCurrent else { return }
                request = prepared
            } catch {
                guard !Task.isCancelled, isCurrent else { return }
                preparationError = error.localizedDescription
            }
        }
    }

    private func delete(_ request: AlbumDeletionRequest) {
        guard !isDeleting, isCurrent, library.canDeleteAlbum(using: request) else { return }
        isDeleting = true
        isStopping = false
        job = Task { @MainActor in
            let outcome = await library.deleteAlbum(request)
            isDeleting = false
            isStopping = false
            job = nil
            guard isCurrent else { return }
            report = outcome
            onFinished(!outcome.deleted.isEmpty && outcome.remainingCount == 0)
        }
    }

    private func stop() {
        guard isDeleting else { return }
        isStopping = true
        library.cancelAlbumDeletion()
    }

    private func endPresentationWork() {
        isPresentationActive = false
        // Let an already-sent delete finish so its acknowledgement can be accounted for.
        // Preparation is read-only and can be canceled immediately.
        if isDeleting { stop() }
        else { job?.cancel() }
    }
}
#endif

/// Renames an album for good by writing the new title into the album tag of each of its songs on
/// the NAS, keeping the release together with its album artist while preserving song credits.
struct AlbumRenameSheet: View {
    let album: Album
    /// Receives the album's id once the write is done: a new one when the title changed.
    let onRenamed: (String) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var isWriting = false
    @State private var isStopping = false
    @State private var writtenTitle = ""
    @State private var report: MetadataWriteReport?
    @FocusState private var isEditingTitle: Bool

    init(album: Album, onRenamed: @escaping (String) -> Void) {
        self.album = album
        self.onRenamed = onRenamed
        _title = State(initialValue: album.title)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { library.canWriteTags && !trimmedTitle.isEmpty && trimmedTitle != album.title && !isWriting }
    private var songCount: Int { library.album(id: album.id)?.tracks.count ?? album.tracks.count }

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    resultSections(report)
                } else if isWriting {
                    Section {
                        TagWriteProgressView(writer: library.metadataWriter, title: "Renaming album", subtitle: writtenTitle, isStopping: isStopping) {
                            isStopping = true
                            library.metadataWriter.cancel()
                        }
                    } footer: {
                        Text("Each song is downloaded, its album tag rewritten and the file put back on your NAS. Songs already written stay written if you stop.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Section {
                        TextField("Title", text: $title)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            .focused($isEditingTitle)
                            .submitLabel(.done)
                            .onSubmit { if canSave { save() } }
                        #if os(macOS)
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                    } header: {
                        Text("Title")
                    } footer: {
                        #if !os(macOS)
                        Text(footer)
                            .fixedSize(horizontal: false, vertical: true)
                        #endif
                    }
                }
            }
            .navigationTitle("Rename Album")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isWriting && report == nil {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if report != nil {
                        Button("Done") { dismiss() }
                    } else if !isWriting {
                        Button("Rename") { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        .sheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWriting)
        .onAppear { isEditingTitle = true }
    }

    @ViewBuilder private func resultSections(_ report: MetadataWriteReport) -> some View {
        Section {
            Label(TagWriteSummary.line(for: report, noun: "title"), systemImage: report.written.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
            ForEach(report.reasons, id: \.self) { reason in
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(report.failures.isEmpty ? "Stopped" : "Some files were left unchanged")
        } footer: {
            if !report.written.isEmpty {
                Text("Songs whose files keep the old title show as a separate album until they can be written too.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: String {
        let songs = "\(songCount) \(songCount == 1 ? "song" : "songs")"
        guard library.canWriteTags else {
            return "Connect to your server to rename this album. The new title is written into its \(songs) on the NAS, so it holds everywhere and survives a rescan."
        }
        return "The title and album artist are saved to \(songs) on your NAS to keep this album together. Song artist credits, year, genre and artwork stay as they are."
    }

    private func save() {
        guard canSave else { return }
        let newTitle = trimmedTitle
        isEditingTitle = false
        writtenTitle = newTitle
        isStopping = false
        isWriting = true
        Task { @MainActor in
            let outcome = await library.renameAlbum(album, to: newTitle)
            isWriting = false
            isStopping = false
            onRenamed(outcome.albumID)
            if outcome.report.isComplete {
                dismiss()
            } else {
                report = outcome.report
            }
        }
    }
}

/// The back of the cover: the album's colours with its year, genre and quality.
struct CoverBack: View {
    let album: Album

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(album.secondaryColor)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        EllipticalGradient(
                            colors: [album.primaryColor.opacity(0.55), .clear],
                            center: UnitPoint(x: 0.3, y: 0.2),
                            startRadiusFraction: 0,
                            endRadiusFraction: 0.8
                        )
                    )
            }
            .overlay {
                VStack(spacing: 6) {
                    Text(album.year > 0 ? String(album.year) : "—")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(album.genre)
                        .font(.title3.weight(.medium))
                    Text(album.qualityLabel)
                        .font(.subheadline)
                        .opacity(0.75)
                        .padding(.top, 10)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(20)
            }
            .accessibilityElement(children: .combine)
    }
}

/// Plain song rows on the page background, separated by hairlines that start at the title.
struct TrackList: View {
    let album: Album
    let tracks: [Track]

    var body: some View {
        // Lazy, so a long compilation lays out only the rows on screen when the page opens.
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(album: album, track: track)
                if index < tracks.count - 1 {
                    Divider().padding(.leading, 38)
                }
            }
        }
    }
}

/// One numbered track line; the loaded track shows a speaker glyph instead of its number.
/// Tapping plays it; the "…" opens favourite and playlist actions.
struct TrackRow: View {
    let album: Album
    let track: Track
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAddingToPlaylist = false

    private var playbackState: PlayerModel.CollectionPlaybackState {
        player.playbackState(for: track, sourceID: library.catalogue.driveID)
    }
    private var isCurrent: Bool { playbackState != .inactive }

    var body: some View {
        let scope = AlbumActionScope(library: library, profiles: profiles)
        HStack(spacing: 0) {
            Button {
                guard scope.isCurrent(library: library, profiles: profiles),
                      let current = library.album(id: album.id),
                      let index = current.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                player.play(album: current, startingAt: index)
            } label: {
                HStack(spacing: 14) {
                    Group {
                        if isCurrent {
                            TrackPlaybackIndicator(state: playbackState)
                        } else {
                            Text(track.number, format: .number)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
                    FadingText(track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                    Spacer(minLength: 8)
                    if library.isFavourite(track) {
                        FavouriteMark()
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                    if let fraction = downloads.progress[track.id] {
                        MiniProgressRing(fraction: fraction)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    } else if downloads.isQueued(track) {
                        Circle()
                            .stroke(.quaternary, lineWidth: 2)
                            .frame(width: 13, height: 13)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                            .accessibilityLabel("Waiting to download")
                    } else if downloads.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                            .accessibilityLabel("Downloaded")
                    }
                    Text(TimeText.clock(track.duration))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: downloads.isDownloaded(track))
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: library.isFavourite(track))
                .padding(.vertical, 17)
                .padding(.leading, 4)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.25), value: isCurrent)
            }
            .buttonStyle(RowPressStyle())
            .accessibilityLabel("\(track.number). \(track.title), \(TimeText.clock(track.duration))")
            .accessibilityValue(playbackState.accessibilityDescription)

            TrackActionsMenu(track: track, isAddingToPlaylist: $isAddingToPlaylist)
                .padding(.leading, 2)
        }
        .sheet(isPresented: $isAddingToPlaylist) {
            AddToPlaylistSheet(tracks: [track])
        }
    }
}

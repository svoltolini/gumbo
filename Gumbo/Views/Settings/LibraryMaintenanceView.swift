import GumboCore
import SwiftUI

/// A review never survives a different server, music folder, or unlocked profile session.
private struct MaintenanceContext: Equatable {
    let source: String
    let root: String
    let session: UUID?
    init(_ library: LibraryStore, _ profiles: ProfileStore) {
        source = library.catalogue.driveID
        root = library.catalogue.rootPath
        session = profiles.sessionID
    }
}

struct MissingGenresView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ProfileStore.self) private var profiles
    @State private var rows: [GenreReviewRow] = []
    @State private var job: Task<Void, Never>?
    @State private var isWorking = false
    @State private var isSaving = false
    @State private var isStopping = false
    @State private var progress = ""
    @State private var currentAlbum: String?
    @State private var lookupProgress: Double = 0
    @State private var summary: String?
    @State private var failures: [MetadataWriteFailure] = []
    @State private var confirmingSave = false
    @State private var uneditableCount = 0

    private var context: MaintenanceContext { MaintenanceContext(library, profiles) }
    private var canStart: Bool { library.canMaintainFiles && !library.metadataWriter.isWriting && !library.isDeletingFiles && !isWorking }
    private var selected: [GenreReviewRow] { rows.filter { $0.selected && !GenreLookup.isMissing($0.genre) && $0.genre.count <= 100 } }

    var body: some View {
        Form {
            Section {
                Text("Find a suggested genre for albums with missing tags, then choose what to save. This updates the music files on your NAS for everyone who uses them.")
                Text("When you choose Find Suggestions, album and artist names are sent to Apple's music catalogue. Audio, file paths and NAS sign-in details are not sent.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Find Suggestions") { findSuggestions() }
                    .disabled(!canStart || rows.isEmpty)
                if !library.canMaintainFiles { Text("Connect as the library owner to change shared music files.").font(.footnote) }
                if uneditableCount > 0 {
                    Text("\(uneditableCount) songs need their information refreshed or use a format Gumbo cannot edit. Those files will be kept unchanged.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if isWorking {
                Section {
                    if isSaving {
                        TagWriteProgressView(writer: library.metadataWriter, title: "Saving genres", subtitle: progress, isStopping: isStopping, onStop: stop)
                    } else {
                        OperationProgressView(title: "Finding genres", subtitle: progress, currentItem: currentAlbum,
                                              fractionCompleted: lookupProgress, isStopping: isStopping, onStop: stop)
                    }
                }
            }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--sample-library"),
               ProcessInfo.processInfo.arguments.contains("--ui-preview"),
               ProcessInfo.processInfo.arguments.contains("--preview-genre-progress") {
                Section { GenreProgressPreview() }
            }
            #endif
            if let summary { Section { Text(summary) } }
            if rows.isEmpty && !isWorking {
                Section { Text("No editable songs with missing genres were found.") }
            }
            Section {
                ForEach($rows) { $row in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $row.selected) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.album).font(.headline)
                                Text(row.artist).font(.subheadline).foregroundStyle(.secondary)
                                Text("\(row.trackIDs.count) songs with missing genres").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isWorking || GenreLookup.isMissing(row.genre))
                        TextField("Genre", text: $row.genre)
                            .disabled(isWorking)
                            .accessibilityLabel("Genre for \(row.album)")
                        if row.genre.count > 100 {
                            Text("Use 100 characters or fewer for a genre.").font(.caption).foregroundStyle(.red)
                        }
                        if let source = row.source {
                            Link("Suggested by Apple Music", destination: source).font(.caption)
                        }
                        if let note = row.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 4)
                }
            } header: { if !rows.isEmpty { Text("Review Genres") } } footer: {
                Text("Suggestions use an exact album and artist match. If there is no clear match, enter a genre yourself. Existing genres are checked again and kept when you save.")
            }
            if !rows.isEmpty {
                Section {
                    Button("Save Genres to NAS (\(selected.count))") { confirmingSave = true }
                        .disabled(!canStart || selected.isEmpty)
                }
            }
            MaintenanceFailures(failures: failures)
        }
        .groupedForm()
        .navigationTitle("Find Missing Genres")
        .inlineTitle()
        .onAppear { loadAlbums() }
        .onChange(of: context) { _, _ in stop(); rows = []; failures = []; summary = nil; loadAlbums() }
        .onDisappear { stop() }
        .confirmationDialog("Save genres to your music files?", isPresented: $confirmingSave, titleVisibility: .visible) {
            Button("Save to NAS") { saveSelected() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The selected genres will be written to the original files for all NAS users. Existing genre tags will be kept. Other devices will see the changes after updating their libraries.")
        }
    }

    private func loadAlbums() {
        guard !isWorking else { return }
        var skipped = 0
        rows = library.albums.compactMap { album in
            let missing = album.tracks.filter { GenreLookup.isMissing($0.genreTag) }
            let editable = missing.filter {
                $0.isEnriched && $0.duration > 0 && $0.path.map { TagWriter.supports(fileName: ($0 as NSString).lastPathComponent) } == true
            }
            skipped += missing.count - editable.count
            guard !editable.isEmpty else { return nil }
            return GenreReviewRow(id: album.id, album: album.title, artist: album.artist, trackIDs: Set(editable.map(\.id)))
        }
        uneditableCount = skipped
    }

    private func stop() {
        guard isWorking else { return }
        isStopping = true
        job?.cancel()
        if isSaving { library.metadataWriter.cancel() }
    }

    private func findSuggestions() {
        guard canStart else { return }
        let scope = context
        isWorking = true
        isStopping = false
        progress = ""
        currentAlbum = nil
        lookupProgress = 0
        failures = []
        summary = nil
        job = Task { @MainActor in
            defer { isWorking = false; isStopping = false; job = nil; if context != scope { loadAlbums() } }
            for index in rows.indices {
                guard !Task.isCancelled, context == scope else { break }
                progress = "Album \(index + 1) of \(rows.count)"
                lookupProgress = Double(index) / Double(rows.count)
                let album = rows[index]
                currentAlbum = album.album
                // Preserve manual edits and previously reviewed choices when lookup is repeated.
                guard GenreLookup.isMissing(album.genre) else { continue }
                do {
                    let suggestion = try await GenreLookup.shared.suggestion(album: album.album, artist: album.artist)
                    guard !Task.isCancelled, context == scope, rows.indices.contains(index), rows[index].id == album.id else { break }
                    rows[index].genre = suggestion?.genre ?? ""
                    rows[index].source = suggestion?.sourceURL
                    rows[index].note = suggestion == nil ? "No clear match. You can enter a genre yourself." : nil
                } catch {
                    guard !Task.isCancelled, context == scope else { break }
                    summary = "Genre lookup is unavailable. Try again later, or enter genres yourself."
                    break // Avoid repeated failures and rate-limit storms.
                }
            }
        }
    }

    private func saveSelected() {
        guard canStart else { return }
        let choices = selected
        let scope = context
        isWorking = true
        isSaving = true
        isStopping = false
        progress = ""
        failures = []
        summary = nil
        job = Task { @MainActor in
            defer { isWorking = false; isSaving = false; isStopping = false; job = nil; if context != scope { loadAlbums() } }
            var saved = 0
            var kept = 0
            var stopped = false
            for (index, choice) in choices.enumerated() {
                guard !Task.isCancelled, context == scope else { stopped = true; break }
                progress = "Album \(index + 1) of \(choices.count) · \(choice.album)"
                let result = await library.fillMissingGenre(choice.genre, trackIDs: choice.trackIDs)
                guard context == scope else { return }
                saved += result.written.count
                kept += result.unchanged.count
                failures += result.failures
                if let row = rows.firstIndex(where: { $0.id == choice.id }) {
                    let finished = Set((result.written + result.unchanged).map(\.id))
                    rows[row].trackIDs.subtract(finished)
                    if rows[row].trackIDs.isEmpty { rows[row].selected = false }
                }
                if result.wasCancelled { stopped = true; break }
            }
            guard context == scope else { return }
            rows.removeAll { $0.trackIDs.isEmpty }
            summary = "Saved genres to \(saved) songs. Kept existing genres in \(kept) songs."
                + (failures.isEmpty ? "" : " \(failures.count) songs could not be changed; see the details below.")
                + (stopped ? " Stopped before the remaining songs were tried." : "")
        }
    }
}

private struct GenreReviewRow: Identifiable {
    let id: String
    let album: String
    let artist: String
    var trackIDs: Set<String>
    var genre = ""
    var selected = false
    var source: URL?
    var note: String?
}

struct ProblemFilesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ProfileStore.self) private var profiles
    @State private var findings: [MusicFileInspection] = []
    @State private var selected: Set<String> = []
    @State private var job: Task<Void, Never>?
    @State private var isWorking = false
    @State private var isStopping = false
    @State private var isDeleting = false
    @State private var progress = ""
    @State private var currentFile: String?
    @State private var checkedProgress: Double?
    @State private var summary: String?
    @State private var failures: [MetadataWriteFailure] = []
    @State private var confirmingDelete = false

    private var context: MaintenanceContext { MaintenanceContext(library, profiles) }
    private var canStart: Bool { library.canInspectFiles && !library.metadataWriter.isWriting && !library.isDeletingFiles && !isWorking }
    private var chosen: [MusicFileInspection] { findings.filter { $0.canDelete && selected.contains($0.id) } }

    var body: some View {
        Form {
            Section {
                Text("Check songs with missing playback information. Only empty files or confirmed MP4 structural damage can be selected for deletion. Connection errors, unfamiliar formats and recent files are kept.")
                Button("Check Files") { inspectFiles() }.disabled(!canStart)
                if !library.canInspectFiles { Text("Connect to a music server to check its files.").font(.footnote) }
            }
            if isWorking {
                Section {
                    OperationProgressView(title: isDeleting ? "Deleting files" : "Checking files",
                                          currentItem: currentFile, fractionCompleted: checkedProgress,
                                          counter: progress.isEmpty ? nil : progress,
                                          isStopping: isStopping, onStop: stop)
                }
            }
            if let summary { Section { Text(summary) } }
            ForEach(findings) { finding in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(finding.track.title).font(.headline)
                        Text(finding.track.path ?? "No file path").font(.caption).foregroundStyle(.secondary).selectableText()
                        Text(finding.explanation).font(.callout)
                        if finding.canDelete && library.canDeleteInspectedFiles {
                            Toggle("Select for deletion", isOn: Binding(
                                get: { selected.contains(finding.id) },
                                set: { if $0 { selected.insert(finding.id) } else { selected.remove(finding.id) } }
                            ))
                            .disabled(isWorking)
                        }
                    }
                }
            }
            if !chosen.isEmpty && library.canDeleteInspectedFiles {
                Section {
                    Button("Delete \(chosen.count) Files from NAS", role: .destructive) { confirmingDelete = true }
                        .disabled(!canStart)
                } footer: {
                    Text("Deletion removes the original files for all NAS users. Other devices remove downloaded copies after a successful library refresh. Apple Watch updates when it syncs with iPhone. Gumbo cannot undo this.")
                }
            }
            MaintenanceFailures(failures: failures)
        }
        .groupedForm()
        .navigationTitle("Problem Files")
        .inlineTitle()
        .onChange(of: context) { _, _ in stop(); findings = []; selected = []; summary = nil; failures = [] }
        .onDisappear { stop() }
        .confirmationDialog("Permanently delete \(chosen.count) files?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete from NAS", role: .destructive) { deleteChosen() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("These are shared originals. Gumbo will check the selected files again, then delete only those that are still damaged and unchanged. Stop any downloads or conversions into this folder first. This cannot be undone in Gumbo.")
        }
    }

    private func stop() {
        guard isWorking else { return }
        isStopping = true
        job?.cancel()
    }

    private func inspectFiles() {
        guard canStart, let drive = library.drive as? any RemoteFileDrive else { return }
        let candidates = library.tracks.filter(MusicFileInspector.needsInspection)
        let scope = context
        findings = []; selected = []; failures = []; summary = nil
        isWorking = true
        isStopping = false
        isDeleting = false
        checkedProgress = 0
        currentFile = nil
        progress = "0 of \(candidates.count) files"
        job = Task { @MainActor in
            defer { isWorking = false; isStopping = false; job = nil }
            for (index, track) in candidates.enumerated() {
                guard !Task.isCancelled, context == scope else { break }
                currentFile = track.title
                let finding = await MusicFileInspector.inspect(track, drive: drive)
                guard !Task.isCancelled, context == scope else { break }
                findings.append(finding)
                progress = "\(index + 1) of \(candidates.count) files"
                checkedProgress = Double(index + 1) / Double(candidates.count)
            }
            guard context == scope else { return }
            let damaged = findings.filter(\.canDelete).count
            summary = "Checked \(findings.count) of \(candidates.count) files. \(damaged) have confirmed structural damage or are empty."
                + (Task.isCancelled ? " The check was stopped." : "")
                + " Nothing has been deleted. This check does not decode every song in your library."
        }
    }

    private func deleteChosen() {
        guard canStart, library.canDeleteInspectedFiles else { return }
        let review = chosen
        let scope = context
        isWorking = true
        isStopping = false
        isDeleting = true
        progress = "Rechecking selected files before deleting"
        currentFile = nil
        checkedProgress = nil
        job = Task { @MainActor in
            defer { isWorking = false; isStopping = false; isDeleting = false; job = nil }
            let report = await library.deleteReviewedFiles(review)
            guard context == scope else { return }
            let removed = Set(report.deleted.map(\.id))
            findings.removeAll { removed.contains($0.id) }
            selected.subtract(removed)
            failures = report.failures
            summary = "Deleted \(report.deleted.count) files from the NAS."
                + (report.failures.isEmpty ? "" : " \(report.failures.count) files could not be deleted; see the details below.")
                + (report.wasCancelled ? " Stopped before the remaining files were tried." : "")
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Layout-only sample: never starts a metadata writer or changes the sample-library permission gates.
private struct GenreProgressPreview: View {
    @State private var isStopping = false

    var body: some View {
        OperationProgressView(title: "Saving genres", subtitle: "Album 1 of 2 · Parallel Lives",
                              currentItem: "A Song with a Longer Name (Live at the Evening Sessions)",
                              fractionCompleted: 4.0 / 15, counter: "4 of 15 songs", isStopping: isStopping) {
            isStopping = true
        }
    }
}
#endif

private struct MaintenanceFailures: View {
    let failures: [MetadataWriteFailure]
    var body: some View {
        if !failures.isEmpty {
            Section("Could Not Finish") {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.title)
                        Text(failure.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

import Foundation

/// One song whose tags could not be written, with the reason in the words the screen shows.
public nonisolated struct MetadataWriteFailure: Identifiable, Sendable, Hashable {
    public let trackID: String
    public let title: String
    public let message: String
    public var id: String { trackID }

    public init(trackID: String, title: String, message: String) {
        self.trackID = trackID
        self.title = title
        self.message = message
    }
}

/// What came of writing tags to a set of songs.
public nonisolated struct MetadataWriteReport: Sendable {
    /// Songs whose files now carry the new tags; each track already reflects them.
    public var written: [Track] = []
    /// Songs whose files already had the values, so nothing was transferred.
    public var unchanged: [Track] = []
    public var failures: [MetadataWriteFailure] = []
    /// True when the person stopped the job before every song was tried.
    public var wasCancelled = false

    public init() {}

    public var attempted: Int { written.count + unchanged.count + failures.count }
    public var isComplete: Bool { failures.isEmpty && !wasCancelled }

    /// Each distinct reason the failed songs gave, most common first.
    public var reasons: [String] {
        var counts: [String: Int] = [:]
        for failure in failures { counts[failure.message, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
}

/// Why a song was skipped before or after the file itself was handled.
public nonisolated enum MetadataWriteError: LocalizedError, Sendable, Equatable {
    case notConnected
    case notAuthorized
    case noFile
    case busy
    /// The rewritten file did not read back with the expected tags, so it never left the device.
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: "Open your profile again before changing music files."
        case .notConnected: "Not connected to the server."
        case .noFile: "This song has no file on the server."
        case .busy: "Another tag change is still being written."
        case .verificationFailed: "The rewritten file didn't read back correctly, so the original was kept."
        }
    }
}

/// Writes tag changes into songs on the server, one file at a time: each is downloaded whole,
/// rewritten with only the requested fields changed, read back with the indexer's own parsers,
/// then swapped into place beside the original. Progress is published for the screen that asked.
@Observable
public final class MetadataWriter {
    public private(set) var isWriting = false
    public private(set) var completed = 0
    public private(set) var total = 0
    public private(set) var currentTitle: String?
    private var job: Task<MetadataWriteReport, Never>?
    private let helperClientFactory: (TagServiceConfiguration) throws -> RemoteTagService

    public init() { helperClientFactory = { try $0.client() } }

    /// Network fixtures avoid reading real helper tokens from the Keychain.
    init(helperClientFactory: @escaping (TagServiceConfiguration) throws -> RemoteTagService) {
        self.helperClientFactory = helperClientFactory
    }

    public var progress: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    /// Stops before the next swap when possible; files already swapped in stay written.
    public func cancel() {
        job?.cancel()
    }

    public func write(_ edits: TagEdits, to tracks: [Track], drive: any RemoteDrive, onlyIfGenreMissing: Bool = false, helper: TagServiceConfiguration? = nil, authorized: @escaping @MainActor @Sendable () -> Bool = { true }) async -> MetadataWriteReport {
        guard !isWriting else {
            var report = MetadataWriteReport()
            report.failures = tracks.map { MetadataWriteFailure(trackID: $0.id, title: $0.title, message: MetadataWriteError.busy.localizedDescription) }
            return report
        }
        isWriting = true
        total = tracks.count
        completed = 0
        currentTitle = tracks.first?.title
        defer {
            isWriting = false
            currentTitle = nil
        }
        let job = Task {
            if let helper {
                return await runRemote(edits, tracks: tracks, drive: drive, configuration: helper, onlyIfGenreMissing: onlyIfGenreMissing, authorized: authorized)
            }
            guard let writable = drive as? any WritableRemoteDrive, drive.capabilities.supportsTagReplacement else {
                var report = MetadataWriteReport()
                report.failures = tracks.map { MetadataWriteFailure(trackID: $0.id, title: $0.title, message: RemoteWriteError.unsupported.localizedDescription) }
                return report
            }
            return await run(edits, tracks: tracks, drive: writable, onlyIfGenreMissing: onlyIfGenreMissing, authorized: authorized)
        }
        self.job = job
        let report = await job.value
        if self.job == job { self.job = nil }
        return report
    }

    private func runRemote(_ edits: TagEdits, tracks: [Track], drive: any RemoteDrive, configuration: TagServiceConfiguration,
                           onlyIfGenreMissing: Bool, authorized: @escaping @MainActor @Sendable () -> Bool) async -> MetadataWriteReport {
        var report = MetadataWriteReport()
        guard !edits.isEmpty else { return report }
        do {
            guard configuration.sourceID == drive.id else { throw MetadataWriteError.notAuthorized }
            let client = try helperClientFactory(configuration)
            _ = try await client.capabilities()
            for track in tracks {
                if Task.isCancelled { report.wasCancelled = true; break }
                currentTitle = track.title
                do {
                    guard authorized(), let path = track.path else { throw MetadataWriteError.notAuthorized }
                    let relative = try configuration.relativePath(path)
                    let before = try await client.stat(path: relative)
                    guard track.fileSize == nil || track.fileSize == before.expected.size else { throw RemoteWriteError.changed }
                    if let modified = track.sourceModifiedAt, modified.isFinite, modified >= 0 {
                        guard floor(modified) == floor(Double(before.expected.mtimeNs) / 1_000_000_000) else { throw RemoteWriteError.changed }
                    }
                    try Task.checkCancellation()
                    guard authorized() else { throw MetadataWriteError.notAuthorized }
                    let edit = RemoteTagService.Edit(path: relative, expected: before.expected,
                        changes: .init(album: edits.albumValue(replacing: before.fields.album), albumArtist: edits.albumArtist, genre: edits.genre), onlyIfGenreMissing: onlyIfGenreMissing)
                    let outcome = try await Self.remoteEdit(client, edit: edit, authorized: authorized)
                    switch outcome.status {
                    case .succeeded, .unchanged:
                        guard let after = outcome.after else { throw RemoteTagService.Error.invalidResponse }
                        var updated = track
                        updated.albumTitleTag = after.fields.album
                        updated.albumArtistTag = after.fields.albumArtist
                        updated.genreTag = after.fields.genre
                        updated.fileSize = after.size
                        updated.sourceModifiedAt = Double(after.mtimeNs) / 1_000_000_000
                        updated.sourceVersion = nil
                        updated.normalizeDiscFromAlbumTag()
                        if outcome.status == .succeeded { report.written.append(updated) }
                        else { report.unchanged.append(updated) }
                    case .cancelled: report.wasCancelled = true
                    default:
                        throw RemoteTagService.Error.service(code: outcome.error?.code ?? "unconfirmed",
                            message: outcome.error?.message ?? "The helper couldn't confirm this edit. Refresh song information before trying again.")
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { report.wasCancelled = true }
                    // A failed helper is never followed by a whole-file upload: its earlier request may have committed.
                    report.failures.append(MetadataWriteFailure(trackID: track.id, title: track.title, message: error.localizedDescription))
                    if Task.isCancelled { break }
                    if case RemoteTagService.Error.service(let code, _) = error,
                       ["unconfirmed", "recovery_required", "recovery_needed"].contains(code) { break }
                }
                completed += 1
            }
        } catch {
            report.failures = tracks.map { MetadataWriteFailure(trackID: $0.id, title: $0.title, message: error.localizedDescription) }
        }
        return report
    }

    private static func remoteEdit(_ client: RemoteTagService, edit: RemoteTagService.Edit,
                                   authorized: @escaping @MainActor @Sendable () -> Bool) async throws -> RemoteTagService.FileOutcome {
        let id = UUID()
        return try await withTaskCancellationHandler {
            var job: RemoteTagService.Job
            do { job = try await client.submit(jobID: id, files: [edit]) }
            catch {
                // Only transport/invalid-response failures may hide a committed submission.
                // Preserve deterministic request/auth failures instead of masking them with a status lookup.
                guard error is CancellationError || (error as? RemoteTagService.Error) == .unavailable
                    || (error as? RemoteTagService.Error) == .invalidResponse else { throw error }
                do { job = try await Task.detached { try await client.status(jobID: id) }.value }
                catch {
                    job = try await terminalAfterCancellation(client, jobID: id,
                        message: "The helper couldn't confirm whether this edit started. Refresh song information before retrying.")
                }
            }
            let deadline = ContinuousClock.now + .seconds(120)
            var cancellationSent = false
            while !job.status.isTerminal {
                if Task.isCancelled || !authorized() {
                    if !cancellationSent {
                        do { job = try await Task.detached { try await client.cancel(jobID: id) }.value }
                        catch {
                            throw RemoteTagService.Error.service(code: "unconfirmed", message: "The helper couldn't confirm that this edit stopped. Further edits have stopped. Refresh song information before trying again.")
                        }
                        cancellationSent = true
                    }
                }
                if job.status.isTerminal { break }
                guard ContinuousClock.now < deadline else {
                    job = try await terminalAfterCancellation(client, jobID: id,
                        message: "The helper is still working or its response was lost. Refresh song information before retrying this edit.")
                    break
                }
                do {
                    job = try await Task.detached {
                        try await Task.sleep(for: .milliseconds(250))
                        return try await client.status(jobID: id)
                    }.value
                } catch {
                    job = try await terminalAfterCancellation(client, jobID: id,
                        message: "Contact with the helper was lost during this edit. Further edits have stopped. Refresh song information before trying again.")
                }
            }
            guard !job.dryRun, job.files.count == 1, let outcome = job.files.first, outcome.path == edit.path else {
                throw RemoteTagService.Error.service(code: "unconfirmed", message: "The helper returned an unexpected result. Refresh song information before trying again.")
            }
            if outcome.status == .succeeded {
                guard let fields = outcome.after?.fields,
                      edit.changes.album.map({ $0 == fields.album }) ?? true,
                      edit.changes.albumArtist.map({ $0 == fields.albumArtist }) ?? true,
                      edit.changes.genre.map({ $0 == fields.genre }) ?? true else {
                    throw RemoteTagService.Error.service(code: "unconfirmed", message: "The helper couldn't verify the requested tags. Refresh song information before trying again.")
                }
            }
            return outcome
        } onCancel: {
            Task.detached { _ = try? await client.cancel(jobID: id) }
        }
    }

    /// Cancellation is also a final status query: a committed file must still be accounted for.
    /// A running/unknown response is not proof that the NAS file was left untouched.
    private static func terminalAfterCancellation(_ client: RemoteTagService, jobID: UUID,
                                                  message: String) async throws -> RemoteTagService.Job {
        if let job = try? await Task.detached(operation: { try await client.cancel(jobID: jobID) }).value,
           job.status.isTerminal { return job }
        throw RemoteTagService.Error.service(code: "unconfirmed", message: message)
    }

    private func run(_ edits: TagEdits, tracks: [Track], drive: any WritableRemoteDrive, onlyIfGenreMissing: Bool = false, authorized: @escaping @MainActor @Sendable () -> Bool = { true }) async -> MetadataWriteReport {
        var report = MetadataWriteReport()
        guard !edits.isEmpty else { return report }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "gumbo-tag-writes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // A refusal to write is the account's, not the song's; the rest would fail the same way.
        var denial: String?
        for track in tracks {
            if Task.isCancelled {
                report.wasCancelled = true
                break
            }
            currentTitle = track.title
            if let denial {
                report.failures.append(MetadataWriteFailure(trackID: track.id, title: track.title, message: denial))
                completed += 1
                continue
            }
            do {
                guard authorized() else { throw MetadataWriteError.notAuthorized }
                let result = try await Self.rewrite(track: track, edits: edits, drive: drive, scratch: scratch,
                                                    onlyIfGenreMissing: onlyIfGenreMissing, authorized: authorized)
                if result.changed { report.written.append(result.track) }
                else { report.unchanged.append(result.track) }
            } catch {
                if case RemoteWriteError.recoveryNeeded = error {
                    // A cancelled operation may still need recovery; do not hide that in a
                    // generic "stopped" result or proceed to change more songs.
                    report.failures.append(MetadataWriteFailure(trackID: track.id, title: track.title, message: error.localizedDescription))
                    report.wasCancelled = Task.isCancelled
                    diagnostics("Tag replacement needs checking: \(error.localizedDescription)")
                    break
                }
                if Task.isCancelled || error is CancellationError {
                    report.wasCancelled = true
                    break
                }
                let message = Self.message(for: error)
                report.failures.append(MetadataWriteFailure(trackID: track.id, title: track.title, message: message))
                if error.isWriteDenied { denial = message }
                diagnostics("Tags for \(track.path ?? track.title) were not written: \(message)")
            }
            completed += 1
        }
        if !report.written.isEmpty {
            diagnostics("Wrote tags to \(report.written.count) songs" + (report.failures.isEmpty ? "" : ", \(report.failures.count) failed") + (report.wasCancelled ? ", then stopped" : ""))
        }
        return report
    }

    nonisolated struct RewriteResult: Sendable {
        let track: Track
        let changed: Bool
    }

    /// Reads current file tags before filling a missing genre, so stale caches cannot overwrite one.
    @concurrent nonisolated static func rewrite(track: Track, edits: TagEdits, drive: any WritableRemoteDrive, scratch: URL,
                                               onlyIfGenreMissing: Bool = false,
                                               authorized: @escaping @MainActor @Sendable () -> Bool = { true }) async throws -> RewriteResult {
        guard drive.capabilities.supportsTagReplacement else { throw RemoteWriteError.unsupported }
        guard let path = track.path else { throw MetadataWriteError.noFile }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard TagWriter.supports(fileName: name) else { throw TagWriteError.unsupportedFormat(ext) }
        let remote = try await drive.info(path)
        guard !remote.isDirectory, let size = remote.size, size > 0, remote.modified != nil else { throw RemoteWriteError.incompleteTransfer }
        if let version = track.sourceVersion, version != remote.version { throw RemoteWriteError.changed }
        if onlyIfGenreMissing {
            // The suggestion belonged to the reviewed album. A different file may now occupy
            // that path; require a library refresh instead of classifying its replacement.
            if let reviewedSize = track.fileSize, reviewedSize != size { throw RemoteWriteError.changed }
            if let reviewedTime = track.sourceModifiedAt, reviewedTime != remote.modified?.timeIntervalSince1970 {
                throw RemoteWriteError.changed
            }
        }
        guard size <= TagWriter.maximumFileSize else { throw TagWriteError.tooLarge }
        let directory = scratch.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "original.\(ext)")
        let patched = directory.appending(path: "patched.\(ext)")
        try await drive.downloadFile(path, to: original, maxBytes: size)
        guard try localSize(original) == size else { throw RemoteWriteError.incompleteTransfer }
        try Task.checkCancellation()
        guard let before = try await TagWriter.readBack(fileName: name, at: original) else {
            throw MetadataWriteError.verificationFailed
        }
        if onlyIfGenreMissing, !GenreLookup.isMissing(before.genre) {
            var current = track
            current.genreTag = before.genre
            current.fileSize = remote.size
            current.sourceModifiedAt = remote.modified?.timeIntervalSince1970
            current.sourceVersion = remote.version
            return RewriteResult(track: current, changed: false)
        }
        guard try TagWriter.rewrite(edits: edits, fileName: name, source: original, destination: patched) else {
            var current = track
            current.albumTitleTag = before.album
            current.albumArtistTag = before.albumArtist
            current.genreTag = before.genre
            current.normalizeDiscFromAlbumTag()
            current.fileSize = remote.size
            current.sourceModifiedAt = remote.modified?.timeIntervalSince1970
            current.sourceVersion = remote.version
            return RewriteResult(track: current, changed: false)
        }
        let newSize = try localSize(patched)
        guard let after = try await TagWriter.readBack(fileName: name, at: patched) else {
            throw MetadataWriteError.verificationFailed
        }
        try verify(before: before, after: after, edits: edits)
        try Task.checkCancellation()
        // A second later than before: every device notices the changed file on its next scan, while
        // the album keeps its place in Recently Added.
        let modified = Date(timeIntervalSince1970: ((remote.modified ?? .now).timeIntervalSince1970 + 1).rounded(.down))
        guard await authorized() else { throw MetadataWriteError.notAuthorized }
        try Task.checkCancellation()
        try await drive.replaceFile(at: path, with: patched, expectedSize: newSize, modified: modified,
                                    expectedOriginal: remote, authorized: authorized)
        var updated = track
        if let genre = edits.genre { updated.genreTag = genre }
        if edits.albumArtist != nil { updated.albumArtistTag = after.albumArtist }
        if edits.album != nil {
            updated.albumTitleTag = after.album
            updated.normalizeDiscFromAlbumTag()
        }
        updated.fileSize = newSize
        updated.sourceModifiedAt = modified.timeIntervalSince1970
        updated.sourceVersion = nil
        return RewriteResult(track: updated, changed: true)
    }

    /// The edited fields must read back as asked, and everything else exactly as before.
    nonisolated static func verify(before: WrittenTags, after: WrittenTags, edits: TagEdits) throws {
        guard after.title == before.title, after.artist == before.artist, after.trackNumber == before.trackNumber else {
            throw MetadataWriteError.verificationFailed
        }
        if let artist = edits.albumArtist {
            guard after.albumArtist == artist else { throw MetadataWriteError.verificationFailed }
        } else {
            guard after.albumArtist == before.albumArtist else { throw MetadataWriteError.verificationFailed }
        }
        if let genre = edits.genre {
            guard after.genre == genre else { throw MetadataWriteError.verificationFailed }
        } else {
            guard after.genre == before.genre else { throw MetadataWriteError.verificationFailed }
        }
        if edits.album != nil {
            guard after.album == edits.albumValue(replacing: before.album) else { throw MetadataWriteError.verificationFailed }
        } else {
            guard after.album == before.album else { throw MetadataWriteError.verificationFailed }
        }
    }

    nonisolated private static func localSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// The reason in the words the screen shows.
    nonisolated static func message(for error: any Error) -> String {
        if error.isWriteDenied { return RemoteWriteError.readOnly.localizedDescription }
        if error.isMissingPath { return RemoteWriteError.missing.localizedDescription }
        return error.localizedDescription
    }
}

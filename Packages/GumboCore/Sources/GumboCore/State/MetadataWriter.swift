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

    public init() {}

    public var progress: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    /// Stops before the next swap when possible; files already swapped in stay written.
    public func cancel() {
        job?.cancel()
    }

    public func write(_ edits: TagEdits, to tracks: [Track], drive: any WritableRemoteDrive, onlyIfGenreMissing: Bool = false, authorized: @escaping @MainActor @Sendable () -> Bool = { true }) async -> MetadataWriteReport {
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
        let job = Task { await run(edits, tracks: tracks, drive: drive, onlyIfGenreMissing: onlyIfGenreMissing, authorized: authorized) }
        self.job = job
        let report = await job.value
        if self.job == job { self.job = nil }
        return report
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
        guard let path = track.path else { throw MetadataWriteError.noFile }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard TagWriter.supports(fileName: name) else { throw TagWriteError.unsupportedFormat(ext) }
        let remote = try await drive.info(path)
        guard !remote.isDirectory, let size = remote.size, size > 0, remote.modified != nil else { throw RemoteWriteError.incompleteTransfer }
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

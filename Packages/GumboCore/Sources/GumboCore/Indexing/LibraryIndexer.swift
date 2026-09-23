import Foundation
import GumboShared

/// Walks a drive to build the catalogue, then reads tags and covers in the background.
@Observable
public final class LibraryIndexer {
    public enum Phase: Equatable {
        case idle, scanning, enriching, done, failed(Failure)
    }

    /// Why a scan produced no library, worded for the screen; the technical detail goes to Diagnostics.
    public nonisolated enum Failure: Equatable, Sendable {
        case noMusic(path: String)
        case unreadable(count: Int, path: String)
        case missing(path: String)
        case other(String)

        public var title: String {
            switch self {
            case .noMusic: "No music in this folder"
            case .unreadable: "Some folders couldn't be read"
            case .missing: "This folder no longer exists"
            case .other: "Couldn't read the folder"
            }
        }

        /// One short line under the title, only when it helps.
        public var detail: String? {
            switch self {
            case .noMusic, .missing: nil
            case .unreadable(_, let path): "Check that this account can open everything in “\(Self.name(of: path))”."
            case .other(let message): message
            }
        }

        public static func name(of path: String) -> String {
            path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    public private(set) var phase: Phase = .idle
    /// Requests in flight at once. Over a home link the NAS is the limit; over the internet it is
    /// latency, and a dozen requests at a time hides most of it.
    nonisolated static let parallelism = 12
    public private(set) var foldersScanned = 0
    public private(set) var tracksFound = 0
    public private(set) var enrichedCount = 0
    public private(set) var enrichTotal = 0
    public private(set) var listingFailures = 0
    public private(set) var coversDone = 0
    public private(set) var coversTotal = 0
    private var task: Task<Void, Never>?
    private var currentRun: IndexingRun?
    nonisolated private let recordDiagnostics: @Sendable (String) -> Void

    public init() {
        recordDiagnostics = { diagnostics($0) }
    }

    init(recordDiagnostics: @escaping @Sendable (String) -> Void) {
        self.recordDiagnostics = recordDiagnostics
    }

    public var isRunning: Bool { phase == .scanning || phase == .enriching }
    public var isScanning: Bool { phase == .scanning }
    public var isEnriching: Bool { phase == .enriching }
    /// True once albums exist, even while tags are still being read.
    public var structureReady: Bool { phase == .enriching || phase == .done }
    public var enrichProgress: Double { enrichTotal > 0 ? Double(enrichedCount) / Double(enrichTotal) : 1 }

    public var statusText: String? {
        switch phase {
        case .scanning: "Scanning…"
        case .enriching:
            if coversTotal > 0 && coversDone < coversTotal {
                "Scanning · covers \(coversDone.formatted()) of \(coversTotal.formatted())"
            } else if enrichTotal > 0 && enrichedCount < enrichTotal {
                "Scanning · \(Int((enrichProgress * 100).rounded()))%"
            } else {
                "Checking for changes…"
            }
        default: nil
        }
    }

    private var lastProgressPublish = Date.distantPast

    private func checkActive(_ run: IndexingRun) throws {
        try Task.checkCancellation()
        guard currentRun === run, run.isActive else { throw CancellationError() }
    }

    /// Check ownership on the UI actor immediately before publishing a worker's result.
    private func publish(_ catalogue: Catalogue, run: IndexingRun, to onCatalogue: @MainActor (Catalogue) -> Void) throws {
        try checkActive(run)
        onCatalogue(catalogue)
        try checkActive(run)
    }

    private func publishProgress(run: IndexingRun, enriched: Int? = nil, covers: Int? = nil, force: Bool = false) throws {
        try checkActive(run)
        noteEnrichProgress(enriched: enriched, covers: covers, force: force)
    }

    /// Progress reaches the screen at most twice a second. Every published change re-evaluates the
    /// views that show it, and on a wide window with a large library that is the whole Library
    /// screen; publishing per song once froze the Mac app for minutes (2026-09-13).
    private func noteScanProgress(folders: Int, tracks: Int) {
        guard Date.now.timeIntervalSince(lastProgressPublish) > 0.5 else { return }
        lastProgressPublish = .now
        foldersScanned = folders
        tracksFound = tracks
    }

    /// Same pacing for the tag and cover counters; `force` publishes the final value.
    private func noteEnrichProgress(enriched: Int? = nil, covers: Int? = nil, force: Bool = false) {
        guard force || Date.now.timeIntervalSince(lastProgressPublish) > 0.5 else { return }
        lastProgressPublish = .now
        if let enriched, enrichedCount != enriched { enrichedCount = enriched }
        if let covers, coversDone != covers { coversDone = covers }
    }

    /// Scans `rootPath` on the drive; `onCatalogue` receives the catalogue when the structure is known and again as tags arrive.
    public func start(drive: any RemoteDrive, rootPath: String, serverName: String, existing: Catalogue?, forceMetadataReread: Bool = false, onVerifiedListing: (@MainActor (Catalogue) -> Void)? = nil, onCatalogue: @escaping @MainActor (Catalogue) -> Void) {
        cancel()
        let run = IndexingRun()
        currentRun = run
        phase = .scanning
        foldersScanned = 0
        tracksFound = 0
        enrichedCount = 0
        enrichTotal = 0
        listingFailures = 0
        coversDone = 0
        coversTotal = 0
        lastProgressPublish = .distantPast
        recordDiagnostics("Scan started at \(rootPath) on \(drive.displayName)")
        if forceMetadataReread { recordDiagnostics("Reading all song tags again was requested") }
        let sourceCovers = CoverStore.scopedDirectory(driveID: drive.id, rootPath: rootPath)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                run.cancel()
                if currentRun === run {
                    currentRun = nil
                    task = nil
                }
            }
            await CoverStore.$directoryOverride.withValue(sourceCovers) {
            await CoverStore.$indexingRun.withValue(run) {
                do {
                    let scan = try await Self.scan(drive: drive, root: rootPath, recordDiagnostics: recordDiagnostics) { [weak self] scanned, found in
                        Task { @MainActor in
                            guard let self, self.currentRun === run, run.isActive else { return }
                            self.noteScanProgress(folders: scanned, tracks: found)
                        }
                    }
                    try checkActive(run)
                    listingFailures = scan.failures
                    foldersScanned = scan.foldersListed
                    recordDiagnostics("Scan finished: \(scan.foldersListed) folders listed, \(scan.filesSeen) files seen, \(scan.folders.reduce(0) { $0 + $1.audio.count }) audio files, \(scan.failures) listing failures\(scan.firstError.map { ", first error: \($0)" } ?? "").")
                    // A partial answer cannot establish what was deleted. Keep the complete previous
                    // catalogue until every subtree can be read, including on background refreshes.
                    guard scan.failures == 0 else {
                        recordDiagnostics("Refresh incomplete; the previous library was kept.")
                        phase = .failed(.unreadable(count: scan.failures, path: rootPath))
                        return
                    }
                    let folders = scan.folders
                    if folders.isEmpty {
                        if scan.foldersListed == 0 {
                            // Not one folder was read, not even the root, and nothing failed: that is the
                            // scanner going wrong, never a real answer. The library people have is kept.
                            recordDiagnostics("Scan listed no folders at all under \(rootPath); keeping the library as it was.")
                            phase = .failed(.other("The server didn't answer for this folder. Your library was kept; try again."))
                            return
                        }
                        if existing != nil {
                            // Every folder was read and none holds music: the library really is empty now.
                            recordDiagnostics("Scan found no music under \(rootPath); the library is now empty.")
                            let empty = Catalogue(serverName: serverName, albums: [], indexedAt: .now, rootPath: rootPath, driveID: drive.id)
                            onVerifiedListing?(empty)
                            try checkActive(run)
                            onCatalogue(empty)
                            try checkActive(run)
                            phase = .done
                            return
                        }
                        recordDiagnostics("No music files were found under \(rootPath); \(scan.filesSeen.formatted()) other files were seen.")
                        phase = .failed(.noMusic(path: rootPath))
                        return
                    }
                    let driveID = drive.id
                    let coverDirectory = CoverStore.directory
                    let catalogue = await Task.detached(priority: .userInitiated) {
                        CoverStore.$directoryOverride.withValue(coverDirectory) {
                            CoverStore.$indexingRun.withValue(run) {
                                var built = Catalogue.build(folders: folders, rootPath: rootPath, serverName: serverName, driveID: driveID, existing: existing, forceMetadataReread: forceMetadataReread)
                                Catalogue.discardFinderMetadataCovers(previous: existing, driveID: driveID, rootPath: rootPath)
                                if run.isActive, built.enrichedTrackCount > 0 { built.regroupByTags() }
                                return built
                            }
                        }
                    }.value
                    try checkActive(run)
                    tracksFound = catalogue.trackCount
                    // Only a complete, successful listing can prove which files disappeared.
                    // Missing-root errors and partial scans must never purge offline downloads.
                    onVerifiedListing?(catalogue)
                    try checkActive(run)
                    onCatalogue(catalogue)
                    try checkActive(run)
                    phase = .enriching
                    try await runEnrichment(catalogue: catalogue, drive: drive, run: run, onCatalogue: onCatalogue)
                    try checkActive(run)
                    phase = .done
                } catch is CancellationError {
                    return
                } catch {
                    guard currentRun === run, run.isActive, !Task.isCancelled else { return }
                    if error.isMissingPath {
                        // The chosen folder itself is gone; show an empty library rather than the old one.
                        recordDiagnostics("The folder \(rootPath) no longer exists; the library is now empty.")
                        if existing != nil {
                            onCatalogue(Catalogue(serverName: serverName, albums: [], indexedAt: .now, rootPath: rootPath, driveID: drive.id))
                        }
                        guard currentRun === run, run.isActive else { return }
                        phase = .failed(.missing(path: rootPath))
                    } else {
                        recordDiagnostics("Scan failed: \(error.localizedDescription)")
                        phase = .failed(.other(error.localizedDescription))
                    }
                }
            }
        }
        }
    }

    public func cancel() {
        currentRun?.cancel()
        currentRun = nil
        task?.cancel()
        task = nil
        if isRunning { phase = .idle }
    }

    // MARK: Scanning

    /// One folder's listing as it comes back from a worker. A plain struct on purpose: a tuple with a
    /// `Result` inside came back corrupted from worker tasks in release builds (2026-09-13).
    nonisolated private struct Listing: Sendable {
        let path: String
        let entries: [RemoteEntry]
        let error: (any Error)?
    }

    nonisolated private struct ScanResult: Sendable {
        var folders: [ScannedFolder] = []
        var foldersListed = 0
        var filesSeen = 0
        var failures = 0
        var firstError: String?
    }

    /// Breadth-first walk with a few listings in flight; unreadable folders are counted and skipped.
    @concurrent nonisolated private static func scan(drive: any RemoteDrive, root: String, recordDiagnostics: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> ScanResult {
        var result = ScanResult()
        var queue = [root]
        var found = 0
        var isFirst = true
        var lastProgress = ContinuousClock.now
        // The folder each queued folder was listed in, and the cover image of every folder listed so
        // far, music or not: "CD1" and "CD2" often share the album's cover one level up.
        var parents: [String: String] = [:]
        var covers: [String: RemoteEntry] = [:]
        while !queue.isEmpty {
            try Task.checkCancellation()
            let batch = Array(queue.prefix(parallelism))
            queue.removeFirst(batch.count)
            let listings: [Listing] = await parallelResults(batch) { path in
                do {
                    return Listing(path: path, entries: try await drive.list(path), error: nil)
                } catch {
                    return Listing(path: path, entries: [], error: error)
                }
            }
            try Task.checkCancellation()
            for listing in listings.sorted(by: { $0.path < $1.path }) {
                let path = listing.path
                if let error = listing.error {
                    if isFirst { throw error }
                    result.failures += 1
                    if result.firstError == nil { result.firstError = "\(path): \(error.localizedDescription)" }
                    continue
                }
                let entries = listing.entries
                isFirst = false
                let directories = entries.filter { $0.isDirectory && !$0.name.hasPrefix(".") && $0.name != "@eaDir" && $0.name != "#recycle" }
                queue.append(contentsOf: directories.map(\.path))
                for directory in directories { parents[directory.path] = path }
                let cover = RemoteDriveSupport.coverImage(in: entries)
                if let cover { covers[path] = cover }
                let audio = entries.filter(\.isAudio)
                result.filesSeen += entries.filter { !$0.isDirectory }.count
                if result.foldersListed < 3 {
                    recordDiagnostics("Listed \(path): \(entries.count) entries, \(directories.count) folders, \(audio.count) audio. Sample: \(entries.prefix(3).map { "\($0.name)\($0.isDirectory ? "/" : "")" }.joined(separator: ", "))")
                }
                if !audio.isEmpty {
                    // Breadth first, so the parent was listed in an earlier batch.
                    result.folders.append(ScannedFolder(path: path, audio: audio, cover: cover,
                                                        parentCover: parents[path].flatMap { covers[$0] }))
                    found += audio.count
                }
                result.foldersListed += 1
                // Throttle before enqueuing UI work, not just after a main-actor task is created.
                if lastProgress.duration(to: .now) >= .milliseconds(500) {
                    progress(result.foldersListed, found)
                    lastProgress = .now
                }
            }
        }
        return result
    }

    // MARK: Enrichment

    /// What looking for an album's cover found.
    nonisolated enum CoverLookup: Sendable {
        /// The image and a description of where it came from.
        case found(Data, String)
        /// Every place was looked at and none holds a picture.
        case absent
        /// A request failed on the way, e.g. the connection dropped, so absence is not established.
        case failed(String)
    }

    /// A cover fetched for an album, as a struct for the same reason as `Listing`.
    nonisolated private struct CoverFetch: Sendable {
        let album: Album
        let lookup: CoverLookup
    }

    nonisolated private struct EnrichmentResult: Sendable {
        let track: Track
        let cover: Data?
        /// Reading the file failed on the way, not because of the file; it does not count as an attempt.
        var interrupted = false
    }

    // `nonisolated` alone inherits the caller's executor with NonisolatedNonsendingByDefault.
    // Keep tag processing, artwork decoding and filesystem work on a concurrent executor.
    @concurrent nonisolated private func runEnrichment(catalogue: Catalogue, drive: any RemoteDrive, run: IndexingRun, onCatalogue: @escaping @MainActor (Catalogue) -> Void) async throws {
        try await checkActive(run)
        var working = catalogue
        // Album ids that already asked one of their songs for embedded art; ids change as albums regroup,
        // which at worst costs one extra request per album.
        var coverRequested: Set<String> = []
        // Only songs never read, or read by an older version, and not the ones that already failed
        // three times this week: those wait so a refresh does not read the whole library again.
        let now = Date.now
        var restingCount = 0
        let pending = working.albums.flatMap(\.tracks).filter { track in
            guard !track.isEnriched || track.tagVersion != Track.currentTagVersion else { return false }
            let attempts = track.enrichAttempts ?? 0
            if attempts < 3 { return true }
            if let last = track.enrichAttemptedAt, now.timeIntervalSince(last) < 7 * 24 * 3600 {
                restingCount += 1
                return false
            }
            return true
        }
        let rereads = pending.filter(\.isEnriched).count
        if rereads > 0 { recordDiagnostics("Reading tags again for \(rereads) previously indexed tracks") }
        if restingCount > 0 { recordDiagnostics("Leaving \(restingCount) songs that could not be read three times; they are tried again after a week") }
        if !pending.isEmpty { recordDiagnostics("Reading tags for \(pending.count) songs") }
        try await MainActor.run {
            try checkActive(run)
            enrichTotal = pending.count
            enrichedCount = 0
        }
        var enrichedSoFar = 0
        var interruptedSoFar = 0
        var lastPublish = Date.now

        for start in stride(from: 0, to: pending.count, by: Self.parallelism) {
            try await checkActive(run)
            let chunk = pending[start..<min(start + Self.parallelism, pending.count)]
            // Decide who should bring back a picture using the albums as they are grouped right now.
            var requests: [(track: Track, coverPath: String?, wantsArt: Bool, albumID: String)] = []
            for track in chunk {
                let album = working.album(containing: track.id)
                let albumID = album?.id ?? track.albumID
                let wantsArt = !CoverStore.hasCover(for: albumID) && !coverRequested.contains(albumID)
                if wantsArt { coverRequested.insert(albumID) }
                requests.append((track, wantsArt ? album?.coverPath : nil, wantsArt, albumID))
            }
            let results = await parallelResults(requests) { request in
                await Self.enrich(track: request.track, coverPath: request.coverPath, wantsEmbeddedArt: request.wantsArt, drive: drive)
            }
            try await checkActive(run)
            for result in results {
                var track = result.track
                if !result.interrupted, !track.isEnriched || track.tagVersion != Track.currentTagVersion {
                    // Still not read: remember the failure so it is not retried forever. A dropped
                    // connection says nothing about the file, so that song is simply tried next time.
                    track.enrichAttempts = (track.enrichAttempts ?? 0) + 1
                    track.enrichAttemptedAt = .now
                }
                working.apply(track)
                let request = requests.first { $0.track.id == result.track.id }
                if let cover = result.cover {
                    // Kept per song too, so the album that finally owns this song can adopt it after regrouping.
                    CoverStore.saveTrackCover(cover, for: result.track.id)
                    if let albumID = working.album(containing: result.track.id)?.id, !CoverStore.hasCover(for: albumID) {
                        CoverStore.save(cover, for: albumID)
                    }
                } else if let request, request.wantsArt {
                    // Let a later song of the album try its embedded picture.
                    coverRequested.remove(request.albumID)
                }
                enrichedSoFar += 1
                if result.interrupted { interruptedSoFar += 1 }
            }
            try await publishProgress(run: run, enriched: enrichedSoFar)
            if Date.now.timeIntervalSince(lastPublish) > 6 {
                // Show albums as their tags settle instead of the folder grouping until the very end.
                working = await regroupInBackground(working, run: run)
                try await publish(working, run: run, to: onCatalogue)
                lastPublish = .now
            }
        }
        try await publishProgress(run: run, enriched: enrichedSoFar, force: true)
        if interruptedSoFar > 0 { recordDiagnostics("Couldn't reach \(interruptedSoFar) songs; they are read again on the next refresh") }
        working.indexedAt = .now
        working = await regroupInBackground(working, run: run)
        try await checkActive(run)
        let multiDisc = working.albums.filter(\.hasMultipleDiscs)
        recordDiagnostics("Regrouped by tags: \(working.albums.count) albums, \(multiDisc.count) with more than one disc" + (multiDisc.isEmpty ? "" : ": " + multiDisc.prefix(6).map { "“\($0.title)” (\($0.discs.count))" }.joined(separator: ", ")))
        try await publish(working, run: run, to: onCatalogue)
        let total = try await runCoverPass(catalogue: working, drive: drive, run: run)
        try await publishProgress(run: run, covers: total, force: true)
        CoverStore.clearTrackCovers()
        try await publish(working, run: run, to: onCatalogue)
    }

    /// Partial updates need the same background work and cancellation boundary as the final result.
    /// Grouping thousands of songs on the main actor interrupts scrolling and transport controls.
    nonisolated private func regroupInBackground(_ catalogue: Catalogue, run: IndexingRun) async -> Catalogue {
        let coverDirectory = CoverStore.directory
        return await Task.detached(priority: .userInitiated) {
            CoverStore.$directoryOverride.withValue(coverDirectory) {
                CoverStore.$indexingRun.withValue(run) {
                    var regrouped = catalogue
                    if run.isActive { regrouped.regroupByTags() }
                    return regrouped
                }
            }
        }.value
    }

    /// Fetches a cover for every album that still lacks one, from its folder image or its own tracks.
    @concurrent nonisolated private func runCoverPass(catalogue: Catalogue, drive: any RemoteDrive, run: IndexingRun) async throws -> Int {
        try await checkActive(run)
        // Albums that had no cover anywhere last time are looked at again after a week, not on every refresh.
        let now = Date.now
        var resting = 0
        let missing = catalogue.albums.filter { album in
            guard !CoverStore.hasCover(for: album.id) else { return false }
            if let tried = CoverStore.missingCoverDate(for: album.id), now.timeIntervalSince(tried) < 7 * 24 * 3600 {
                resting += 1
                return false
            }
            return true
        }
        try await MainActor.run {
            try checkActive(run)
            coversTotal = missing.count
            coversDone = 0
        }
        var coversSoFar = 0
        if resting > 0 { recordDiagnostics("Cover pass: \(resting) albums without any cover are left until next week") }
        guard !missing.isEmpty else { return 0 }
        recordDiagnostics("Cover pass: \(missing.count) albums without covers")
        for start in stride(from: 0, to: missing.count, by: Self.parallelism) {
            try await checkActive(run)
            let chunk = missing[start..<min(start + Self.parallelism, missing.count)]
            let results: [CoverFetch] = await parallelResults(Array(chunk)) { album in
                CoverFetch(album: album, lookup: await Self.lookUpCover(for: album, drive: drive))
            }
            try await checkActive(run)
            for fetch in results {
                let album = fetch.album
                switch fetch.lookup {
                case .found(let data, let source):
                    CoverStore.save(data, for: album.id)
                    recordDiagnostics("Cover for “\(album.title)” by \(album.artist): \(source)")
                case .absent:
                    CoverStore.noteMissingCover(for: album.id)
                    recordDiagnostics("No cover found for “\(album.title)” by \(album.artist)")
                case .failed(let reason):
                    // Only a search that reached every place may rest for a week.
                    recordDiagnostics("Cover for “\(album.title)” by \(album.artist) is looked for again next time: \(reason)")
                }
                coversSoFar += 1
            }
            try await publishProgress(run: run, covers: coversSoFar)
        }
        recordDiagnostics("Cover pass finished: \(missing.filter { CoverStore.hasCover(for: $0.id) }.count) covers found")
        return missing.count
    }

    /// Looks in the album's folder image, then in the first songs' embedded pictures. Absence is only
    /// reported when every request got an answer; a dropped connection is `.failed`, not "no cover".
    nonisolated static func lookUpCover(for album: Album, drive: any RemoteDrive) async -> CoverLookup {
        var failure: String?
        func note(_ error: any Error, _ path: String) {
            if failure == nil, !error.isAnswerAboutFile { failure = "\(path): \(error.localizedDescription)" }
        }
        if let coverPath = album.coverPath {
            do {
                let data = try await drive.download(coverPath, maxBytes: ArtworkPolicy.maxArtworkDownloadBytes)
                if !data.isEmpty { return .found(data, "folder image \(coverPath)") }
            } catch {
                note(error, coverPath)
            }
        }
        for track in album.tracks.prefix(3) {
            guard let path = track.path else { continue }
            if track.codec == "flac" {
                do {
                    if let info = try await readFLAC(path: path, drive: drive) {
                        if let picture = info.picture { return .found(picture, "embedded art in \(path)") }
                        continue
                    }
                } catch {
                    note(error, path)
                    continue
                }
                // Not a stream this parser follows; AVFoundation may still find a picture.
            }
            if let source = RemoteMediaSource.resolve(drive: drive, path: path) {
                if let artwork = await MediaProbe.probe(source: source).artwork {
                    return .found(artwork, "embedded art in \(path)")
                }
            }
        }
        if let failure { return .failed(failure) }
        return .absent
    }

    /// Reads one file's headers and tags; FLAC by hand, everything else through AVFoundation.
    nonisolated private static func enrich(track: Track, coverPath: String?, wantsEmbeddedArt: Bool, drive: any RemoteDrive) async -> EnrichmentResult {
        var updated = track
        var cover: Data?
        if let coverPath, let data = try? await drive.download(coverPath, maxBytes: ArtworkPolicy.maxArtworkDownloadBytes), !data.isEmpty {
            cover = data
        }
        guard let path = track.path else {
            updated.isEnriched = true
            updated.tagVersion = Track.currentTagVersion
            return EnrichmentResult(track: updated, cover: cover)
        }
        let filenameTags = PathParser.track(fileName: track.fileName)
        let folderName = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
        let fallbackNumber = filenameTags.number ?? track.index + 1
        let fallbackDisc = filenameTags.disc ?? PathParser.discNumber(in: folderName)
            ?? PathParser.splitDisc(folderName).disc ?? 1

        if track.codec == "flac" {
            let parsed: FLACInfo?
            do {
                parsed = try await readFLAC(path: path, drive: drive)
            } catch {
                guard error.isAnswerAboutFile else { return EnrichmentResult(track: updated, cover: cover, interrupted: true) }
                parsed = nil
            }
            if var info = parsed {
                updated.sampleRate = info.sampleRate ?? updated.sampleRate
                updated.bitDepth = info.bitsPerSample
                if let duration = info.duration { updated.duration = duration }
                if let size = track.fileSize, let bitrate = MediaBounds.bitrate(bytes: size, duration: updated.duration) {
                    updated.bitrate = bitrate
                }
                updated.title = info.tag("TITLE").nonEmpty ?? filenameTags.title
                updated.number = info.number("TRACKNUMBER").flatMap { $0 > 0 ? $0 : nil } ?? fallbackNumber
                updated.disc = info.number("DISCNUMBER").flatMap { $0 > 0 ? $0 : nil } ?? fallbackDisc
                updated.artist = info.tag("ARTIST").nonEmpty ?? filenameTags.artist
                updated.albumTitleTag = info.tag("ALBUM")
                updated.albumArtistTag = info.tag("ALBUMARTIST") ?? info.tag("ALBUM ARTIST")
                updated.yearTag = info.year
                updated.genreTag = info.tag("GENRE")
                updated.normalizeDiscFromAlbumTag()
                updated.format = FormatLabel.make(codec: "flac", sampleRate: updated.sampleRate, bitrate: nil, bitDepth: updated.bitDepth)
                updated.isEnriched = true
                updated.tagVersion = Track.currentTagVersion
                if cover == nil, wantsEmbeddedArt, let picture = info.picture { cover = picture }
                info.picture = nil
                return EnrichmentResult(track: updated, cover: cover)
            }
            // Metadata this parser can't follow, such as an ID3v2 tag too large to skip in front of
            // the stream: AVFoundation reads FLAC too, only more slowly.
        }

        // MP4 and MP3 files are read in one or two ranged requests; anything else still asks AVFoundation,
        // which fetches the file piece by piece and is slow over the internet.
        let probe: ProbedMedia
        let native: ProbedMedia?
        do {
            native = try await readNatively(track: track, path: path, drive: drive)
        } catch {
            guard error.isAnswerAboutFile else { return EnrichmentResult(track: updated, cover: cover, interrupted: true) }
            native = nil
        }
        if let native {
            probe = native
        } else {
            guard let source = RemoteMediaSource.resolve(drive: drive, path: path) else { return EnrichmentResult(track: updated, cover: cover) }
            probe = await MediaProbe.probe(source: source)
        }
        // An unavailable or failed parser must not erase the last successful tags. A successful
        // parse may omit a removed tag, in which case filename/folder defaults apply again.
        guard probe.duration != nil || probe.title != nil else {
            return EnrichmentResult(track: updated, cover: cover)
        }
        if let duration = probe.duration { updated.duration = duration }
        if let codec = probe.codec, !codec.isEmpty { updated.codec = codec }
        updated.sampleRate = probe.sampleRate ?? updated.sampleRate
        if let bits = probe.bitsPerChannel, bits > 0 { updated.bitDepth = bits }
        if let bitrate = probe.bitrate {
            updated.bitrate = bitrate
        } else if let size = track.fileSize, let duration = probe.duration,
                  let bitrate = MediaBounds.bitrate(bytes: size, duration: duration) {
            updated.bitrate = bitrate
        }
        updated.title = probe.title.nonEmpty ?? filenameTags.title
        updated.number = probe.trackNumber.flatMap { $0 > 0 ? $0 : nil } ?? fallbackNumber
        updated.disc = probe.discNumber.flatMap { $0 > 0 ? $0 : nil } ?? fallbackDisc
        updated.artist = probe.artist.nonEmpty ?? filenameTags.artist
        updated.albumTitleTag = probe.album
        updated.albumArtistTag = probe.albumArtist
        updated.yearTag = probe.year
        updated.genreTag = probe.genre
        updated.normalizeDiscFromAlbumTag()
        updated.format = FormatLabel.make(codec: updated.codec, sampleRate: updated.sampleRate, bitrate: updated.isLossless ? nil : updated.bitrate, bitDepth: updated.bitDepth)
        updated.isEnriched = true
        updated.tagVersion = Track.currentTagVersion
        if cover == nil, wantsEmbeddedArt, let artwork = probe.artwork { cover = artwork }
        return EnrichmentResult(track: updated, cover: cover)
    }

    /// Nil when the file is not in a format read here or could not be parsed; throws when a read failed.
    nonisolated private static func readNatively(track: Track, path: String, drive: any RemoteDrive) async throws -> ProbedMedia? {
        let read: (Range<Int64>) async throws -> Data = { range in try await drive.read(path, range: range) }
        switch (path as NSString).pathExtension.lowercased() {
        case "m4a", "mp4", "aac", "alac":
            return try await MP4Tags.read(read: read)
        case "mp3":
            return try await ID3Tags.read(fileSize: track.fileSize, read: read)
        default:
            return nil
        }
    }

    /// Indexing needs the stream details and the comments, not every block: a huge embedded picture
    /// must not cost a song its tags.
    nonisolated private static func readFLAC(path: String, drive: any RemoteDrive) async throws -> FLACInfo? {
        try await FLACHeader.read(requireAllBlocks: false) { range in try await drive.read(path, range: range) }
    }
}

import Foundation
import Synchronization
import Testing
@testable import GumboCore

private actor IndexingTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    private(set) var arrivals = 0
    private var released = false

    func wait() async {
        entered = true
        arrivals += 1
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}

private nonisolated final class ReliabilityDrive: RemoteDrive {
    let id: String
    let displayName = "Indexing test drive"
    let tree: [String: [RemoteEntry]]
    let failingPath: String?
    let failure: URLError.Code
    let listingGate: IndexingTestGate?
    let readGate: IndexingTestGate?
    let artwork: Data?

    init(id: String = "indexing-test", tree: [String: [RemoteEntry]], failingPath: String? = nil,
         failure: URLError.Code = .timedOut, listingGate: IndexingTestGate? = nil, readGate: IndexingTestGate? = nil, artwork: Data? = nil) {
        self.id = id
        self.tree = tree
        self.failingPath = failingPath
        self.failure = failure
        self.listingGate = listingGate
        self.readGate = readGate
        self.artwork = artwork
    }

    func roots() async throws -> [RemoteEntry] { [] }

    func list(_ path: String) async throws -> [RemoteEntry] {
        if let listingGate { await listingGate.wait() }
        if path == failingPath { throw URLError(failure) }
        return tree[path] ?? []
    }

    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        // Deliberately ignores cancellation, as a provider callback already in flight can do.
        if let readGate { await readGate.wait() }
        return Data()
    }

    func download(_ path: String, maxBytes: Int64) async throws -> Data {
        if let artwork, path.hasSuffix("cover.png") { return artwork }
        throw URLError(.fileDoesNotExist)
    }
    func streamURL(for path: String) -> URL? { nil }
}

private nonisolated func scanEntry(_ path: String, directory: Bool = false) -> RemoteEntry {
    RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: directory,
                size: directory ? nil : 1024, modified: nil)
}

@MainActor private func waitForIndexing(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<250 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The indexing operation did not reach its expected state within 2.5 seconds")
}

@MainActor private func withArtworkDirectory(_ body: @MainActor () async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-indexing-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await CoverStore.$directoryOverride.withValue(directory) { try await body() }
}

@Suite(.serialized) @MainActor struct IndexingReliabilityTests {
    @Test(arguments: [false, true])
    func scanProcessingAndArtworkStayOffTheUIThread(cachedTags: Bool) async throws {
        try await withArtworkDirectory {
            let stages = Mutex(Set<String>())
            let indexer = LibraryIndexer(recordDiagnostics: { message in
                for stage in ["Listed ", "Reading tags for ", "Regrouped by tags:", "Cover for "] where message.hasPrefix(stage) {
                    #expect(!Thread.isMainThread, "Scan processing must not block the UI: \(stage)")
                    stages.withLock { $0.insert(stage) }
                }
            })
            let art = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a+V8AAAAASUVORK5CYII="))
            let drive = ReliabilityDrive(tree: ["/music": [scanEntry("/music/Song.flac"), scanEntry("/music/cover.png")]], artwork: art)
            var previous = Catalogue.build(folders: [ScannedFolder(path: "/music", audio: [scanEntry("/music/Song.flac")], cover: scanEntry("/music/cover.png"))], rootPath: "/music", serverName: "NAS", driveID: drive.id, existing: nil)
            previous.albums[0].tracks[0].isEnriched = true
            previous.albums[0].tracks[0].tagVersion = Track.currentTagVersion
            var latest = Catalogue.empty
            indexer.start(drive: drive, rootPath: "/music", serverName: "NAS", existing: cachedTags ? previous : nil) {
                #expect(Thread.isMainThread, "Only publishing belongs on the UI thread")
                latest = $0
            }
            try await waitForIndexing { !indexer.isRunning }
            #expect(indexer.phase == .done)
            let required = ["Listed ", "Regrouped by tags:", cachedTags ? "Cover for " : "Reading tags for "]
            #expect(stages.withLock { $0.isSuperset(of: required) })
            let album = try #require(latest.albums.first)
            #expect(CoverStore.hasCover(for: album.id))
            #expect(try Data(contentsOf: CoverStore.fileURL(for: album.id)) == art)
            #expect(!CoverStore.hasTrackCover(for: album.tracks[0].id), "Temporary artwork is cleaned up after grouping")
        }
    }

    @Test func repeatedManualRefreshDoesNotRestartAnActiveScan() async throws {
        try await withArtworkDirectory {
            let suite = "GumboRefreshTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var services = ConnectionServices()
            services.login = { url, _, _, _ in DSMSession(baseURL: url, sid: "fixture", apis: [:]) }
            services.info = { _ in nil }
            services.deletePassword = { _ in }
            services.log = { _ in }
            let library = LibraryStore()
            let model = AppModel(library: library, defaults: defaults, services: services, restoresSession: false)
            #expect(model.enterAddress("https://nas.example:5001"))
            await model.signIn(account: "fixture", password: "fixture", otpCode: "", remember: false)
            let gate = IndexingTestGate()
            library.drive = ReliabilityDrive(tree: ["/music": []], listingGate: gate)
            model.chooseMusicFolder(path: "/music", showsProgress: false)
            try await waitForIndexing { await gate.entered }
            for _ in 0..<3 {
                model.rescan()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await gate.arrivals == 1, "Repeated pulls must not start duplicate NAS listings")
            #expect(model.isScanning)
            await gate.release()
            try await waitForIndexing { !model.isScanning }
            #expect(model.indexer.phase == .failed(.noMusic(path: "/music")))
        }
    }

    @Test(arguments: [URLError.Code.timedOut, .userAuthenticationRequired, .noPermissionsToReadFile])
    func incompleteRefreshKeepsPreviousCatalogue(failure: URLError.Code) async throws {
        try await withArtworkDirectory {
            let root = "/music"
            let folders = ["A", "B"].map { name in
                ScannedFolder(path: root + "/" + name, audio: [scanEntry(root + "/" + name + "/Song.flac")], cover: nil)
            }
            let previous = Catalogue.build(folders: folders, rootPath: root, serverName: "NAS", driveID: "indexing-test", existing: nil)
            let drive = ReliabilityDrive(tree: [
                root: folders.map { scanEntry($0.path, directory: true) },
                folders[0].path: folders[0].audio
            ], failingPath: folders[1].path, failure: failure)
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var visible = previous
            var publications = 0
            indexer.start(drive: drive, rootPath: root, serverName: "NAS", existing: previous) {
                visible = $0
                publications += 1
            }
            try await waitForIndexing { !indexer.isRunning }
            #expect(indexer.phase == .failed(.unreadable(count: 1, path: root)))
            #expect(indexer.listingFailures == 1)
            #expect(publications == 0)
            #expect(visible.trackCount == 2)
            #expect(visible.indexedAt == previous.indexedAt)
        }
    }

    @Test func completeEmptyRefreshCanRemoveDeletedTracks() async throws {
        try await withArtworkDirectory {
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var publications: [Catalogue] = []
            indexer.start(drive: ReliabilityDrive(tree: ["/music": []]), rootPath: "/music", serverName: "NAS", existing: .empty) {
                publications.append($0)
            }
            try await waitForIndexing { !indexer.isRunning }
            #expect(indexer.phase == .done)
            #expect(publications.count == 1)
            #expect(publications.first?.isEmpty == true)
        }
    }

    @Test func cancelledEnrichmentCannotPublishOrWriteArtwork() async throws {
        try await withArtworkDirectory {
            let gate = IndexingTestGate()
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var publications = 0
            let drive = ReliabilityDrive(tree: ["/old": [scanEntry("/old/Song.flac")]], readGate: gate)
            indexer.start(drive: drive, rootPath: "/old", serverName: "Old NAS", existing: nil) { _ in publications += 1 }
            try await waitForIndexing { await gate.entered }
            #expect(indexer.phase == .enriching)
            #expect(publications == 1)
            indexer.cancel()
            await gate.release()
            try await Task.sleep(for: .milliseconds(100))
            #expect(indexer.phase == .idle)
            #expect(publications == 1)
            #expect(indexer.enrichedCount == 0)
            #expect(!FileManager.default.fileExists(atPath: CoverStore.directory.path))
        }
    }

    @Test(arguments: ["/old", "/new-folder"])
    func newerScanOwnsStateAfterDelayedEnrichment(root: String) async throws {
        try await withArtworkDirectory {
            let gate = IndexingTestGate()
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var publications: [String] = []
            indexer.start(drive: ReliabilityDrive(id: "old", tree: ["/old": [scanEntry("/old/Song.flac")]], readGate: gate),
                          rootPath: "/old", serverName: "Old NAS", existing: nil) { publications.append($0.driveID) }
            try await waitForIndexing { await gate.entered }
            indexer.start(drive: ReliabilityDrive(id: "new", tree: [root: []]), rootPath: root,
                          serverName: "New NAS", existing: .empty) { publications.append($0.driveID) }
            try await waitForIndexing { !indexer.isRunning }
            #expect(indexer.phase == .done)
            await gate.release()
            try await Task.sleep(for: .milliseconds(100))
            #expect(publications == ["old", "new"])
            #expect(indexer.phase == .done)
            #expect(indexer.enrichedCount == 0)
            #expect(indexer.tracksFound == 0)
            #expect(indexer.coversTotal == 0)
        }
    }

    @Test func cancelledRootErrorCannotReplaceNewScanStatus() async throws {
        try await withArtworkDirectory {
            let gate = IndexingTestGate()
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            indexer.start(drive: ReliabilityDrive(tree: [:], failingPath: "/old", listingGate: gate),
                          rootPath: "/old", serverName: "Old NAS", existing: nil) { _ in Issue.record("Cancelled scan published") }
            try await waitForIndexing { await gate.entered }
            indexer.start(drive: ReliabilityDrive(tree: ["/new": []]), rootPath: "/new", serverName: "New NAS", existing: .empty) { _ in }
            try await waitForIndexing { !indexer.isRunning }
            await gate.release()
            try await Task.sleep(for: .milliseconds(100))
            #expect(indexer.phase == .done)
            #expect(indexer.listingFailures == 0)
        }
    }

    @Test func cancellationInsideCatalogueCallbackStopsEnrichment() async throws {
        try await withArtworkDirectory {
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var publications = 0
            indexer.start(drive: ReliabilityDrive(tree: ["/music": [scanEntry("/music/Song.flac")]]),
                          rootPath: "/music", serverName: "NAS", existing: nil) { _ in
                publications += 1
                indexer.cancel()
            }
            try await waitForIndexing { !indexer.isRunning }
            #expect(indexer.phase == .idle)
            #expect(publications == 1)
        }
    }
}

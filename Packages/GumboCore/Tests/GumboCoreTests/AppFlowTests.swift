import Foundation
import Testing
@testable import GumboCore

// Sign-out, music folder changes and scans asked for while they can't start (#228, #230, #232, #234).

@MainActor private final class AppFlowFixture {
    let suite = "GumboAppFlowTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let library = LibraryStore()
    var services = ConnectionServices()
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(3, forKey: "coverCacheVersion")
        // Only scans the test asks for run.
        defaults.set(false, forKey: "watchFolder")
        services.password = { _ in "test password" }
        services.savePassword = { _, _ in }
        services.deletePassword = { _ in }
        services.deleteCatalogue = {}
        services.log = { _ in }
        services.info = { _ in nil }
        services.logout = { _ in }
        services.observeNetwork = { _ in {} }
        services.login = { url, _, _, _ in flowSession(url) }
        services.synologyDrive = { session, name, renewal in
            SynologyDrive(session: session, displayName: name, renewal: renewal) { _ in SynologyFileList(files: [], offset: 0, total: 0) }
        }
        defaults.set(try JSONEncoder().encode(saved), forKey: "connection")
        var catalogue = SampleLibrary.catalogue
        catalogue.driveID = saved.sourceID
        catalogue.rootPath = "/music"
        services.loadCatalogue = { catalogue }
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    func model(restore: Bool) -> AppModel {
        AppModel(library: library, defaults: defaults, services: services, restoresSession: restore)
    }
}

private nonisolated func flowSession(_ url: URL) -> DSMSession {
    let fileStation = SynologyAPIDescriptor(path: "entry.cgi", minVersion: 1, maxVersion: 2)
    return DSMSession(baseURL: url, sid: "flow", apis: ["SYNO.FileStation.List": fileStation, "SYNO.FileStation.Download": fileStation],
                      account: "listener")
}

private actor ListingGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    private var released = false

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}

/// Lists a fixed tree once the gate opens, so a test can look at the library while a scan is under way.
private nonisolated final class GatedDrive: RemoteDrive {
    let id: String
    let displayName = "Gated drive"
    let tree: [String: [RemoteEntry]]
    let gate: ListingGate

    init(id: String, tree: [String: [RemoteEntry]], gate: ListingGate) {
        self.id = id
        self.tree = tree
        self.gate = gate
    }

    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] {
        await gate.wait()
        return tree[path] ?? []
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { Data() }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { throw URLError(.fileDoesNotExist) }
    func streamURL(for path: String) -> URL? { nil }
}

private nonisolated func song(_ path: String) -> RemoteEntry {
    RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: false, size: 1024, modified: nil)
}

@MainActor private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The operation did not reach its expected state within 3 seconds")
}

@MainActor private func withCovers(_ body: @MainActor () async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-app-flow-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await CoverStore.$directoryOverride.withValue(directory) { try await body() }
}

@Suite(.serialized) @MainActor struct AppFlowTests {
    /// Leaving the sample library is a sign-out too: the app clears the player through this (#228).
    @Test func leavingTheSampleLibraryReportsTheSignOut() async throws {
        let f = try AppFlowFixture(); defer { f.cleanUp() }
        let model = f.model(restore: false)
        model.useSampleLibrary()
        model.openLibrary()
        #expect(f.library.isDemo)
        var signedOut = 0
        model.onSignedOut = { signedOut += 1 }
        await model.signOut()
        #expect(signedOut == 1)
        #expect(!f.library.isDemo && model.stage == .welcome)
    }

    /// The library stays on screen, on its own source, while the newly chosen folder is scanned (#230).
    @Test func changingTheFolderKeepsTheLibraryUntilTheNewScanPublishes() async throws {
        try await withCovers {
            let f = try AppFlowFixture(); defer { f.cleanUp() }
            let model = f.model(restore: true)
            try await waitFor { !model.isRestoring }
            #expect(model.isConnected)
            let gate = ListingGate()
            f.library.drive = GatedDrive(id: f.saved.sourceID, tree: ["/music/New": [song("/music/New/01 Song.flac")]], gate: gate)
            model.chooseMusicFolder(path: "/music/New", showsProgress: false)
            try await waitFor { await gate.entered }
            #expect(model.musicPath == "/music/New")
            #expect(model.stage == .ready)
            #expect(f.library.catalogue.rootPath == "/music")
            #expect(f.library.catalogue.driveID == f.saved.sourceID)
            #expect(f.library.catalogue.trackCount == SampleLibrary.catalogue.trackCount)
            await gate.release()
            try await waitFor { f.library.catalogue.rootPath == "/music/New" }
            #expect(f.library.catalogue.trackCount == 1)
            #expect(f.library.catalogue.driveID == f.saved.sourceID)
            try await waitFor { !model.isScanning }
        }
    }

    /// A chosen folder without music is reported; the library already there is not emptied (#230).
    @Test func aNewFolderWithoutMusicLeavesThePreviousLibrary() async throws {
        try await withCovers {
            let f = try AppFlowFixture(); defer { f.cleanUp() }
            let model = f.model(restore: true)
            try await waitFor { !model.isRestoring }
            let gate = ListingGate()
            await gate.release()
            f.library.drive = GatedDrive(id: f.saved.sourceID, tree: ["/music/Empty": []], gate: gate)
            model.chooseMusicFolder(path: "/music/Empty", showsProgress: false)
            try await waitFor { !model.isScanning }
            #expect(model.indexingFailure == .noMusic(path: "/music/Empty"))
            #expect(f.library.catalogue.rootPath == "/music")
            #expect(f.library.catalogue.trackCount == SampleLibrary.catalogue.trackCount)
        }
    }

    /// With nothing of this server's on screen, the placeholder still belongs to the server, never to
    /// the sample library's empty source ID, whose profile data edits would otherwise land in (#230).
    @Test func aFolderChosenWithoutALibraryIsBoundToTheServer() async throws {
        try await withCovers {
            let f = try AppFlowFixture(); defer { f.cleanUp() }
            f.defaults.removeObject(forKey: "connection")
            let model = f.model(restore: false)
            #expect(model.enterAddress("https://nas.example:5001"))
            await model.signIn(account: "listener", password: "test password", otpCode: "", remember: false)
            #expect(model.stage == .chooseFolder)
            let gate = ListingGate()
            f.library.drive = GatedDrive(id: "gated-nas", tree: ["/music": [song("/music/01 Song.flac")]], gate: gate)
            model.chooseMusicFolder(path: "/music", showsProgress: true)
            #expect(model.stage == .indexing)
            #expect(f.library.catalogue.driveID == "gated-nas")
            #expect(f.library.catalogue.rootPath == "/music")
            #expect(f.library.isEmpty && !f.library.isDemo)
            await gate.release()
            try await waitFor { !model.isScanning }
            #expect(f.library.catalogue.trackCount == 1)
        }
    }

    /// Pulling to refresh an offline library reconnects and then scans, rather than doing nothing (#234).
    @Test func aScanAskedForOfflineReconnectsAndThenScans() async throws {
        try await withCovers {
            let f = try AppFlowFixture(); defer { f.cleanUp() }
            var reachable = false
            var logins = 0
            f.services.login = { url, _, _, _ in
                logins += 1
                guard reachable else { throw SynologyError.unreachable("The request timed out.") }
                return flowSession(url)
            }
            let model = f.model(restore: true)
            try await waitFor { !model.isRestoring }
            #expect(!model.isConnected)
            #expect(model.scanBlocker == .offline)
            model.rescan()
            #expect(model.isScanRequestPending)
            // Still unreachable: the request waits and says why.
            try await waitFor { logins == 2 && !model.isReconnecting }
            #expect(model.scanBlocker == .offline)
            #expect(model.isScanRequestPending)
            #expect(model.indexer.phase == .idle)
            reachable = true
            // The first attempt has finished, so this pull sets out again.
            try await Task.sleep(for: .milliseconds(20))
            model.rescan()
            try await waitFor { model.isConnected && model.indexer.phase == .done }
            #expect(logins == 3)
            #expect(!model.isScanRequestPending)
            #expect(model.scanBlocker == nil)
        }
    }

    /// A certificate this device won't trust is named as such, not as a server that can't be reached (#232).
    @Test func certificateFailuresAreReportedAsUntrustedCertificates() {
        let url = URL(string: "https://192.168.1.20:5001/webapi/query.cgi")!
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                     .serverCertificateNotYetValid, .secureConnectionFailed] {
            guard case .untrustedCertificate(let host) = SynologyError.transport(URLError(code), url: url) else {
                Issue.record("\(code) should be reported as an untrusted certificate")
                continue
            }
            #expect(host == "192.168.1.20")
        }
        guard case .unreachable = SynologyError.transport(URLError(.timedOut), url: url) else {
            Issue.record("A timeout is not a certificate problem")
            return
        }
    }
}

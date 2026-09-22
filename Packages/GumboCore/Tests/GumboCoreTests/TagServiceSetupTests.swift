import Foundation
import Testing
@testable import GumboCore

private actor SetupReplies {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var paths: [String] = []
    func response(_ request: URLRequest) async -> Data {
        let path = request.url!.path
        paths.append(path)
        if request.url?.host == "slow.example", path == "/v1/capabilities" {
            await withCheckedContinuation { waiting = $0 }
        }
        if path == "/v1/capabilities" {
            return Data(#"{"version":1,"service":"GumboTagService","fields":["genre"],"formats":["flac"],"maxFiles":128,"maxFileBytes":2147483648,"requiresSHA256":true,"supportsDryRun":true}"#.utf8)
        }
        return Data("""
        {"version":1,"path":"album/song.flac","expected":{"size":12,"mtimeNs":1000000000,"sha256":"\(String(repeating: "a", count: 64))"},"fields":{"genre":"Ambient"}}
        """.utf8)
    }
    func waitForRequest() async throws {
        for _ in 0..<200 {
            if waiting != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(waiting != nil)
    }
    func release() { waiting?.resume(); waiting = nil }
}

private nonisolated final class SetupProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies = SetupReplies()
    static func use(_ value: SetupReplies) { lock.withLock { replies = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let replies = Self.lock.withLock { Self.replies }
        Task { @Sendable [self, replies] in
            let data = await replies.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

private struct SetupDrive: RemoteFileDrive {
    let id: String
    let displayName = "Fixture"
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { Data() }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { Data() }
    func streamURL(for path: String) -> URL? { nil }
    func info(_ path: String) async throws -> RemoteEntry { throw RemoteWriteError.missing }
}

@MainActor private final class SetupFixture {
    let suite = "GumboTagSetup.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let defaults: UserDefaults
    let library = LibraryStore()
    let profiles: ProfileStore
    let replies = SetupReplies()
    var passwords: [String: String] = [:]
    var model: AppModel!
    let token = String(repeating: "t", count: 43)

    /// `hiddenTwinFirst` lists the "._" twin macOS leaves beside the song first, as an older catalogue did.
    init(hiddenTwinFirst: Bool = false) throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(3, forKey: "coverCacheVersion")
        profiles = ProfileStore(directory: directory, defaults: defaults)
        profiles.openAutomaticallyIfPossible()
        library.profiles = profiles
        let provider = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://nas.example/")!)
        let connection = ServerConnection(name: "Fixture", baseURL: provider.endpoint, account: "owner", musicPath: "/music", provider: provider)
        var catalogue = SampleLibrary.catalogue
        catalogue.driveID = connection.sourceID; catalogue.rootPath = "/music"; catalogue.indexedAt = .now
        catalogue.albums = Array(catalogue.albums.prefix(1))
        var track = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalogue.albums[0].tracks[0])) as? [String: Any])
        track["path"] = "/music/album/song.flac"; track["fileSize"] = 12
        var tracks = [try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: track))]
        if hiddenTwinFirst {
            track["id"] = "/music/album/._song.flac"; track["path"] = "/music/album/._song.flac"; track["fileSize"] = 4096
            tracks.insert(try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: track)), at: 0)
        }
        catalogue.albums[0].tracks = tracks
        defaults.set(try JSONEncoder().encode(connection), forKey: "connection")
        passwords[connection.keychainAccount] = "fixture"
        var services = ConnectionServices()
        services.observeNetwork = { _ in {} }
        services.openProvider = { connection, _ in SetupDrive(id: connection.sourceID) }
        services.password = { self.passwords[$0] }
        services.savePassword = { self.passwords[$1] = $0 }
        services.deletePassword = { self.passwords[$0] = nil }
        services.supportsCredentialSync = { false }
        services.loadCatalogue = { catalogue }
        services.deleteCatalogue = { }
        services.log = { _ in }
        services.tagService = { endpoint, token in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SetupProtocol.self]
            return try RemoteTagService(endpoint: endpoint, token: token, configuration: configuration)
        }
        SetupProtocol.use(replies)
        model = AppModel(library: library, defaults: defaults, services: services, restoresSession: true)
        model.profiles = profiles
    }
    func ready() async throws {
        for _ in 0..<200 {
            if !model.isRestoring { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await library.derivationTask?.value
        try #require(model.isConnected && profiles.canManageProfiles)
    }
    func cleanUp() async {
        await model.signOut()
        model = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite(.serialized) @MainActor struct TagServiceSetupTests {
    @Test func laterSetupWinsWhenAnOlderConnectionCheckFinishesLast() async throws {
        let f = try SetupFixture()
        try await f.ready()
        let old = Task { try await f.model.configureTagService(address: "https://slow.example", token: f.token) }
        try await f.replies.waitForRequest()
        try await f.model.configureTagService(address: "https://current.example", token: f.token)
        await f.replies.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(f.model.tagServiceConfiguration?.endpoint.host == "current.example")
        #expect(f.passwords.keys.filter { $0.hasPrefix("metadata-helper-v1:") }.count == 1)
        #expect(await f.replies.paths.filter { $0 == "/v1/files/stat" }.count == 1)
        await f.cleanUp()
    }

    /// The helper reports the real song's 12 bytes; checking the 4 KB twin instead would fail as a changed file.
    @Test func folderMappingIsCheckedOnASongNotItsHiddenTwin() async throws {
        let f = try SetupFixture(hiddenTwinFirst: true)
        try await f.ready()
        try await f.model.configureTagService(address: "https://current.example", token: f.token)
        #expect(f.model.tagServiceConfiguration?.endpoint.host == "current.example")
        #expect(await f.replies.paths.filter { $0 == "/v1/files/stat" }.count == 1)
        await f.cleanUp()
    }

    @Test(arguments: ["cancel", "disable", "signOut"])
    func abandonedSetupCannotPersistCredentialsOrEnableWrites(_ action: String) async throws {
        let f = try SetupFixture()
        try await f.ready()
        let task = Task { try await f.model.configureTagService(address: "https://slow.example", token: f.token) }
        try await f.replies.waitForRequest()
        if action == "cancel" { task.cancel() }
        else if action == "disable" { f.model.disableTagService() }
        else { await f.model.signOut() }
        await f.replies.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(f.model.tagServiceConfiguration == nil)
        #expect(!f.passwords.keys.contains { $0.hasPrefix("metadata-helper-v1:") })
        #expect(await !f.replies.paths.contains("/v1/files/stat"))
        await f.cleanUp()
    }
}

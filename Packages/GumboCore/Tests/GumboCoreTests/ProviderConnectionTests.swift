import CloudKit
import Foundation
import Testing
@testable import GumboCore

private struct ConnectionDrive: RemoteFileDrive {
    let id: String
    let displayName = "Test NAS"
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { Data() }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { Data() }
    func streamURL(for path: String) -> URL? { nil }
    func info(_ path: String) async throws -> RemoteEntry { .init(path: path, name: "song.flac", isDirectory: false, size: 12, modified: .distantPast) }
}

@MainActor private final class ProviderConnectionFixture {
    let name = "GumboProviderTests.\(UUID())"
    let defaults: UserDefaults
    let library = LibraryStore()
    var passwords: [String: String] = [:]
    var services = ConnectionServices()
    var opened: [ServerConnection] = []
    var failure: (any Error)?
    var held: CheckedContinuation<Void, Never>?
    var hold = false
    init() {
        defaults = UserDefaults(suiteName: name)!
        defaults.set(3, forKey: "coverCacheVersion")
        services.openProvider = { connection, _ in
            self.opened.append(connection)
            if self.hold { await withCheckedContinuation { self.held = $0 } }
            if let error = self.failure { throw error }
            return ConnectionDrive(id: connection.sourceID)
        }
        services.login = { _, _, _, _ in Issue.record("A generic provider must not call DSM login"); throw ProviderError.invalidConfiguration }
        services.password = { self.passwords[$0] }
        services.savePassword = { self.passwords[$1] = $0 }
        services.deletePassword = { self.passwords[$0] = nil }
        services.supportsCredentialSync = { false }
        services.loadCatalogue = { nil }
        services.deleteCatalogue = {}
        services.log = { _ in }
    }
    func model(restore: Bool = false) -> AppModel { AppModel(library: library, defaults: defaults, services: services, restoresSession: restore) }
    func cleanUp() { defaults.removePersistentDomain(forName: name) }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
}

private func withPath(_ track: Track, _ path: String) throws -> Track {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
    object["path"] = path
    return try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: object))
}

@Suite @MainActor struct ProviderConnectionTests {
    @Test(arguments: [NASProviderKind.webDAV, .smb])
    func genericLoginUsesExactScopedProvider(_ kind: NASProviderKind) async throws {
        let f = ProviderConnectionFixture(); defer { f.cleanUp() }
        let model = f.model()
        try await model.connect(to: kind == .smb ? "smb://nas.example" : "https://nas.example/music/", provider: kind, share: "music", domain: "WORK")
        await model.signIn(account: "Listener", password: "fixture", otpCode: "", remember: true)
        let connection = try #require(model.connection)
        #expect(connection.providerKind == kind)
        #expect(f.opened.count == 1)
        #expect(model.isConnected)
        #expect(model.stage == .chooseFolder)
        #expect(f.passwords[connection.keychainAccount] == "fixture")
        #expect(!model.canManageNASAccounts)
        await model.signOut()
    }

    @Test func delayedProviderLoginCannotReplaceNewSelection() async throws {
        let f = ProviderConnectionFixture(); defer { f.cleanUp() }
        f.hold = true
        let model = f.model()
        try await model.connect(to: "https://one.example/music/", provider: .webDAV)
        let request = Task { await model.signIn(account: "a", password: "fixture", otpCode: "", remember: true) }
        try await f.wait { f.held != nil }
        try await model.connect(to: "smb://two.example", provider: .smb, share: "music")
        f.held?.resume(); f.held = nil
        await request.value
        #expect(model.connection == nil)
        #expect(model.pendingServer?.provider?.kind == .smb)
        #expect(model.pendingServer?.host == "two.example")
        #expect(f.passwords.isEmpty)
    }

    @Test func retainedTrackCannotReadFromAnotherSourceOrChangedPath() async throws {
        let f = ProviderConnectionFixture(); defer { f.cleanUp() }
        let model = f.model()
        try await model.connect(to: "smb://nas.example", provider: .smb, share: "music")
        await model.signIn(account: "a", password: "fixture", otpCode: "", remember: false)
        let source = try #require(model.connection?.sourceID)
        var catalogue = SampleLibrary.catalogue
        catalogue.driveID = source; catalogue.rootPath = "/"
        catalogue.albums[0].tracks[0] = try withPath(catalogue.albums[0].tracks[0], "/album/song.flac")
        let track = catalogue.albums[0].tracks[0]
        f.library.replace(with: catalogue, drive: ConnectionDrive(id: source))
        await f.library.derivationTask?.value
        #expect(model.downloadSource(for: track) != nil)
        #expect(f.library.mediaSource(for: track) != nil)
        let changed = try withPath(track, "/different/song.flac")
        #expect(model.downloadSource(for: changed) == nil)
        #expect(f.library.mediaSource(for: changed) == nil)
        f.library.drive = ConnectionDrive(id: "another-library")
        #expect(model.downloadSource(for: track) == nil)
        #expect(f.library.mediaSource(for: track) == nil)
        await model.signOut()
    }

    @Test func expiredDAVPasswordOffersSignInAndKeepsCachedLibrary() async throws {
        let f = ProviderConnectionFixture(); defer { f.cleanUp() }
        let config = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://nas.example/music/")!)
        let saved = ServerConnection(name: "NAS", baseURL: config.endpoint, account: "a", musicPath: "/", provider: config)
        f.defaults.set(try JSONEncoder().encode(saved), forKey: "connection")
        f.passwords[saved.keychainAccount] = "old"
        var cached = SampleLibrary.catalogue; cached.driveID = saved.sourceID; cached.rootPath = "/"
        f.services.loadCatalogue = { cached }
        f.failure = WebDAVError.authenticationRequired
        let model = f.model(restore: true)
        try await f.wait { !model.isRestoring }
        #expect(model.pendingServer?.provider == config)
        #expect(model.stage == .ready)
        #expect(f.library.catalogue.trackCount == cached.trackCount)
        #expect(model.connection == saved)
        #expect(!model.isConnected)
        model.cancelSignIn()
    }

    @Test func manualFamilyRevocationRequiresCloudAcknowledgementAndClearsOnlyThisSource() async throws {
        let f = ProviderConnectionFixture(); defer { f.cleanUp() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rejectRemoval = true
        let cloud = CloudSync(services: CloudServices(identity: { "owner" }, sharedZones: { [] }, createZone: { _ in }, subscribe: {},
            changes: { _, token in CloudChangePage(records: [], token: token) },
            modify: { _, records, ids in
                if !ids.isEmpty && rejectRemoval { throw CKError(.networkUnavailable) }
                return .init(saved: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .success($0)) }), deleted: Dictionary(uniqueKeysWithValues: ids.map { ($0, .success(())) }))
            }), persistence: CloudPersistence(directory: directory))
        let model = f.model()
        try await model.connect(to: "https://nas.example/music/", provider: .webDAV)
        await model.signIn(account: "owner", password: "personal", otpCode: "", remember: true)
        #expect(await model.useFamilyAccess(account: "family", password: "shared") == nil)
        await cloud.refresh(reason: "fixture")
        #expect(await model.stopFamilySharing(using: cloud) != nil)
        #expect(await model.acknowledgeManualFamilyRevocation(using: cloud) != nil)
        #expect(model.familyRevocationPending)
        rejectRemoval = false
        #expect(await model.stopFamilySharing(using: cloud)?.contains("NAS administration") == true)
        #expect(model.familyRevocationPending)
        #expect(await model.acknowledgeManualFamilyRevocation(using: cloud) == nil)
        #expect(!model.familyRevocationPending)
        #expect(model.familyAccess == nil)
        #expect(f.passwords[model.connection!.keychainAccount] == "personal")
        await model.signOut()
    }
}

@Suite @MainActor struct ProviderCloudPayloadTests {
    @Test(arguments: [false, true])
    func invalidProviderPayloadKeepsLastKnownFamily(_ wrongType: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = CKRecord(recordType: "Family", recordID: .init(recordName: "family", zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)))
        let configuration = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://nas.example/music/")!)
        record["providerConnection"] = try JSONEncoder().encode(configuration) as CKRecordValue
        record["name"] = "Home"
        record["serverName"] = "NAS"
        record["updatedAt"] = Date(timeIntervalSince1970: 100)
        let cloud = CloudSync(services: CloudServices(identity: { "owner" }, sharedZones: { [] }, createZone: { _ in }, subscribe: {},
            changes: { _, _ in .init(records: [.success(record)], token: nil) },
            modify: { _, records, _ in .init(saved: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .success($0)) })) }),
            persistence: CloudPersistence(directory: directory))
        var arrived: [FamilyInfo] = []
        cloud.onFamilyInfo = { arrived.append($0) }
        await cloud.refresh(reason: "valid provider")
        #expect(cloud.family?.provider == configuration)
        let expected = cloud.family
        if wrongType { record["providerConnection"] = "invalid-data-type" as CKRecordValue }
        else {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
            object["version"] = 999
            record["providerConnection"] = try JSONSerialization.data(withJSONObject: object) as CKRecordValue
        }
        // A legacy-looking address must never downgrade an invalid new-provider payload to DSM.
        record["address"] = "https://other.example:5001"
        record["updatedAt"] = Date(timeIntervalSince1970: 200)
        await cloud.refresh(reason: "unsupported provider")
        #expect(cloud.family == expected)
        #expect(arrived.count == 1)
        guard case .failed = cloud.status else { Issue.record("Malformed provider must surface a sync failure"); return }
    }
}

import Foundation
import AVFoundation
import Testing
@testable import GumboCore

@Suite struct ProviderFoundationTests {
    @Test func legacyDSMIdentityAndCredentialsAreUnchanged() throws {
        let data = Data(#"{"name":"NAS","baseURL":"https://nas.example:5001","account":"Listener","musicPath":"/music"}"#.utf8)
        let saved = try JSONDecoder().decode(ServerConnection.self, from: data)
        #expect(saved.providerKind == .synology)
        #expect(saved.provider == nil)
        #expect(saved.sourceID == NASSource.identifier(baseURL: saved.baseURL, account: "Listener"))
        #expect(saved.legacyKeychainAccount == "https://nas.example:5001|Listener")
        #expect(try JSONDecoder().decode(ServerConnection.self, from: JSONEncoder().encode(saved)) == saved)
    }

    @Test func rootsAccountsProtocolsAndRealmsNeverAlias() throws {
        let url = URL(string: "https://nas.example/music")!
        let dav = try ProviderConfiguration(kind: .webDAV, endpoint: url)
        let other = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://nas.example/other")!)
        let smb = try ProviderConfiguration(kind: .smb, endpoint: URL(string: "smb://nas.example")!, share: "music")
        let realm = try ProviderConfiguration(kind: .smb, endpoint: URL(string: "smb://nas.example")!, share: "music", domain: "OFFICE")
        let ids = [dav.sourceID(account: "a"), dav.sourceID(account: "A"), other.sourceID(account: "a"),
                   smb.sourceID(account: "a"), realm.sourceID(account: "a"), NASSource.identifier(baseURL: url, account: "a")]
        #expect(Set(ids).count == ids.count)
        let canonical = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://NAS.example:443/music/")!)
        #expect(canonical.sourceID(account: "a") == dav.sourceID(account: "a"))
    }

    @Test(arguments: ["http://nas.example/music", "https://user:secret@nas.example/music", "https://nas.example/../music", "https://nas.example/music?token=secret"])
    func unsafeDAVConfigurationFailsClosed(_ address: String) {
        #expect(throws: (any Error).self) { try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: address)!) }
    }

    @Test func unknownProviderVersionNeverBecomesDSM() throws {
        let config = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://nas.example/music/")!)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object["version"] = 42
        #expect(throws: ProviderError.unsupportedVersion) { try JSONDecoder().decode(ProviderConfiguration.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func mismatchedOrNonLegacyConnectionCannotDecodeAsDSM() throws {
        let config = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://nas.example/music/")!)
        let connection = ServerConnection(name: "NAS", baseURL: config.endpoint, account: "listener", musicPath: "/", provider: config)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as? [String: Any])
        object["baseURL"] = "https://other.example/music/"
        #expect(throws: ProviderError.invalidConfiguration) { try JSONDecoder().decode(ServerConnection.self, from: JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "provider")
        object["baseURL"] = "smb://nas.example"
        #expect(throws: ProviderError.invalidConfiguration) { try JSONDecoder().decode(ServerConnection.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func familyHidesNonDSMAddressFromOldClients() throws {
        let config = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://nas.example/music/")!)
        let family = FamilyInfo(name: "Home", serverName: "NAS", serverAccount: "owner", musicPath: "/", updatedAt: .now,
                                address: config.endpoint.absoluteString, provider: config)
        #expect(family.address == nil)
        #expect(family.isReachable)
        #expect(try family.connection(account: "listener").sourceID == config.sourceID(account: "listener"))
        #expect(try JSONDecoder().decode(FamilyInfo.self, from: JSONEncoder().encode(family)) == family)
    }

    @Test func helperMappingCannotEscapeSelectedLibrary() throws {
        let config = TagServiceConfiguration(endpoint: URL(string: "https://helper.example")!, sourceID: "source", libraryRoot: "/music")
        #expect(try config.relativePath("/music/Artist/Album/song.flac") == "Artist/Album/song.flac")
        for path in ["/music2/song.flac", "/music/../private/song.flac", "/music//song.flac", "/music", "song.flac"] {
            #expect(throws: (any Error).self) { try config.relativePath(path) }
        }
    }

    @Test func backgroundAuthRequiresExactOriginalOriginAndSingleAttempt() {
        let original = URL(string: "https://nas.example:5006/music/song.flac")!
        let auth = DownloadAuthentication(origin: NASOrigin(url: original)!, account: "listener", keychainAccount: "provider-key")
        let valid = URLProtectionSpace(host: "nas.example", port: 5006, protocol: "https", realm: "files", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(auth.permits(valid, original: original, current: original, failures: 0))
        #expect(!auth.permits(valid, original: original, current: URL(string: "https://evil.example/song"), failures: 0))
        #expect(!auth.permits(valid, original: original, current: URL(string: "https://nas.example:5006/other/song.flac"), failures: 0))
        #expect(!auth.permits(valid, original: original, current: original, failures: 1))
        let downgrade = URLProtectionSpace(host: "nas.example", port: 80, protocol: "http", realm: "files", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(!auth.permits(downgrade, original: original, current: original, failures: 0))
        let other = URLProtectionSpace(host: "nas.example", port: 443, protocol: "https", realm: "files", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(!auth.permits(other, original: original, current: original, failures: 0))
    }
}

private actor MemoryFileDrive: RemoteFileDrive {
    nonisolated let id = "provider-test"
    nonisolated let displayName = "Fixture"
    let bytes: Data
    var ranges: [Range<Int64>] = []
    var truncate = false
    init(bytes: Data, truncate: Bool = false) { self.bytes = bytes; self.truncate = truncate }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func info(_ path: String) async throws -> RemoteEntry { RemoteEntry(path: path, name: "audio.wav", isDirectory: false, size: Int64(bytes.count), modified: .distantPast) }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        try Task.checkCancellation()
        ranges.append(range)
        if truncate { return Data() }
        return bytes.subdata(in: Int(min(Int64(bytes.count), range.lowerBound))..<Int(min(Int64(bytes.count), range.upperBound)))
    }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { bytes }
    nonisolated func streamURL(for path: String) -> URL? { nil }
}

@Suite struct ProviderTransferTests {
    @Test func boundedTransferCopiesEveryByteAndCleansFailedPartial() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 42, count: 2_500_001)
        let drive = MemoryFileDrive(bytes: bytes)
        let destination = root.appending(path: "download")
        let count = try await ForegroundFileTransfer.copy(drive: drive, path: "/audio.flac", destination: destination, expectedBytes: Int64(bytes.count)) { _ in }
        #expect(count == bytes.count)
        #expect(try Data(contentsOf: destination) == bytes)
        let ranges = await drive.ranges
        #expect(ranges.count == 3)
        #expect(ranges.allSatisfy { $0.count <= 1024 * 1024 })
        let broken = MemoryFileDrive(bytes: bytes, truncate: true)
        await #expect(throws: ProviderError.invalidResponse) {
            try await ForegroundFileTransfer.copy(drive: broken, path: "/audio.flac", destination: destination, expectedBytes: Int64(bytes.count)) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func mediaProbeReadsAnAuthenticatedByteSourceWithoutAStreamURL() async throws {
        var audio = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { audio.append(contentsOf: $0) }
        }
        append(UInt32(36 + 16_000)); audio.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(16_000))
        append(UInt16(2)); append(UInt16(16)); audio.append(Data("data".utf8)); append(UInt32(16_000))
        audio.append(Data(repeating: 0, count: 16_000))
        let drive = MemoryFileDrive(bytes: audio)
        let local = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        try audio.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let localResult = await MediaProbe.probe(url: local)
        #expect(abs((localResult.duration ?? 0) - 1) < 0.01)
        #expect(localResult.sampleRate == 8_000)
        let result = await MediaProbe.probe(source: .file(drive: drive, path: "/audio.wav"))
        #expect(abs((result.duration ?? 0) - 1) < 0.01)
        #expect(result.sampleRate == 8_000)
        #expect(!(await drive.ranges).isEmpty)
        // Exercise the same AVPlayerItem(asset:) path used by authenticated NAS playback.
        let transport = AVPlaybackTransport(source: .file(drive: drive, path: "/audio.wav"))
        defer { transport.invalidate() }
        let deadline = ContinuousClock.now + .seconds(10)
        while transport.status == .loading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.status == .ready)
        #expect(abs((transport.duration ?? 0) - 1) < 0.01)
        var seekFinished: Bool?
        transport.seek(to: 0.5) { seekFinished = $0 }
        let seekDeadline = ContinuousClock.now + .seconds(10)
        while seekFinished == nil, ContinuousClock.now < seekDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(seekFinished == true)

        let broken = AVPlaybackTransport(source: .file(drive: MemoryFileDrive(bytes: audio, truncate: true), path: "/audio.wav"))
        defer { broken.invalidate() }
        let failureDeadline = ContinuousClock.now + .seconds(10)
        while broken.status == .loading, ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = broken.status else {
            Issue.record("A truncated remote stream must fail, not become playable or stay loading")
            return
        }
    }
}

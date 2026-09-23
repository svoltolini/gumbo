import Foundation
import Testing
@testable import GumboCore
#if canImport(CGumboSMB)
import CGumboSMB
#endif

@Suite struct SMBDriveTests {
    @Test(arguments: [UInt32(0xC0000064), 0xC000006A, 0xC000006D, 0xC0000071,
                      0xC0000072, 0xC0000193, 0xC0000224, 0xC0000234])
    func connectionRejectionAsksForSignIn(_ status: UInt32) throws {
        let error = try #require(SMBDriveError.authenticationFailure(for: status))
        #expect(error == .authenticationRequired)
        #expect(error.requiresProviderSignIn)
    }

    @Test(arguments: [UInt32(0), 0xC0000022, 0xC0000034, 0xC00000CC, 0xC00000B5])
    func filePermissionsMissingSharesAndTimeoutsAreNotLoginRejections(_ status: UInt32) {
        #expect(SMBDriveError.authenticationFailure(for: status) == nil)
    }

    @Test(arguments: ["https://nas.local", "smb://user:secret@nas.local", "smb://nas.local/music", "smb://nas.local?x=1", "smb://nas.local#folder"])
    func rejectsUnsafeEndpoint(_ value: String) throws {
        #expect(throws: SMBDriveError.invalidEndpoint) {
            try SMBConnectionSettings(endpoint: #require(URL(string: value)), share: "Music", account: "sam", security: .encrypted)
        }
    }

    @Test(arguments: ["", "guest", "Anonymous", "DOMAIN\\guest", "sam\0other"])
    func rejectsGuestAndInvalidAccounts(_ account: String) {
        #expect(throws: SMBDriveError.credentialsRequired) {
            try SMBConnectionSettings(endpoint: URL(string: "smb://nas.local")!, share: "Music", account: account, security: .signed)
        }
    }

    @Test(arguments: ["", "..", ".", "a/b", "a\\b", "bad\0share"])
    func rejectsSharesThatCouldEscape(_ share: String) {
        #expect(throws: SMBDriveError.invalidShare) {
            try SMBConnectionSettings(endpoint: URL(string: "smb://nas.local")!, share: share, account: "sam", security: .signed)
        }
    }

    @Test func endpointPreservesPortDomainAndLiteralShare() throws {
        let settings = try SMBConnectionSettings(endpoint: URL(string: "smb://[::1]:1445")!, share: "Music & Films", account: "HOME\\sam", security: .encrypted)
        #expect(settings.server == "[::1]:1445")
        #expect(settings.user == "sam")
        #expect(settings.domain == "HOME")
        #expect(settings.share == "Music & Films")
    }

    @Test(arguments: ["../song.mp3", "/album/../../song.mp3", "//other/share/song.mp3", "album\\song.mp3", "album/./song.mp3", "bad\0name"])
    func rejectsTraversalBeforeTransport(_ path: String) async throws {
        let session = FakeSMBReadSession()
        let drive = try makeDrive(session)
        await #expect(throws: SMBDriveError.invalidPath) { try await drive.list(path) }
        #expect(await session.paths.isEmpty)
    }

    @Test func listingsKeepLiteralNamesAndSkipLinks() async throws {
        let session = FakeSMBReadSession()
        await session.setEntries([
            .init(name: "..", isDirectory: true, isSymbolicLink: false, size: 0, modified: nil),
            .init(name: "escape", isDirectory: false, isSymbolicLink: true, size: 10, modified: nil),
            .init(name: "音楽 & #%.flac", isDirectory: false, isSymbolicLink: false, size: 123, modified: nil)
        ])
        let drive = try makeDrive(session)
        let roots = try await drive.roots()
        #expect(roots.map(\.path) == ["/"])
        #expect(roots[0].name == "Music")
        let files = try await drive.list("/Album%20Name")
        #expect(files.map(\.path) == ["/Album%20Name/音楽 & #%.flac"])
        #expect(await session.paths == ["Album%20Name"])
        #expect(drive.streamURL(for: files[0].path) == nil)
    }

    @Test func malformedListingNeverBecomesAPath() async throws {
        let session = FakeSMBReadSession()
        await session.setEntries([.init(name: "../outside.mp3", isDirectory: false, isSymbolicLink: false, size: 10, modified: nil)])
        await #expect(throws: SMBDriveError.invalidResponse) { try await makeDrive(session).list("/") }
    }

    /// libsmb2 reports STATUS_BAD_NETWORK_NAME and STATUS_NO_SUCH_DEVICE as ENOENT. At the share's
    /// root that is a detached or not yet mounted volume, never a deleted music folder.
    @Test func missingShareRootIsUnavailableNotDeleted() async throws {
        let session = FakeSMBReadSession()
        await session.setFailure(.missingPath)
        let drive = try makeDrive(session)
        await #expect(throws: SMBDriveError.shareUnavailable) { try await drive.list("/") }
        await #expect(throws: SMBDriveError.shareUnavailable) { try await drive.info("/") }
        await #expect(throws: SMBDriveError.missingPath) { try await drive.list("/Music") }
        await #expect(throws: SMBDriveError.missingPath) { try await drive.info("/Music/Song.flac") }
        #expect(!SMBDriveError.shareUnavailable.isMissingPath)
        #expect(SMBDriveError.missingPath.atShareRoot == .shareUnavailable)
        #expect(SMBDriveError.timedOut.atShareRoot == .timedOut)
        await session.setFailure(.disconnected)
        await #expect(throws: SMBDriveError.disconnected) { try await drive.list("/") }
    }

    @Test @MainActor func unavailableShareKeepsTheSavedLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-smb-share-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await CoverStore.$directoryOverride.withValue(directory) {
            let session = FakeSMBReadSession()
            await session.setFailure(.missingPath)
            let drive = try makeDrive(session)
            let song = RemoteEntry(path: "/Album/Song.flac", name: "Song.flac", isDirectory: false, size: 10, modified: nil)
            let saved = Catalogue.build(folders: [ScannedFolder(path: "/Album", audio: [song], cover: nil)], rootPath: "/",
                                        serverName: "NAS", driveID: drive.id, existing: nil)
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var published: [Catalogue] = []
            indexer.start(drive: drive, rootPath: "/", serverName: "NAS", existing: saved, onCatalogue: { published.append($0) })
            for _ in 0..<500 where indexer.isRunning { try await Task.sleep(for: .milliseconds(10)) }
            #expect(published.isEmpty, "The saved library must not be replaced by an empty one")
            #expect(indexer.phase == .failed(.other(SMBDriveError.shareUnavailable.localizedDescription)))
        }
    }

    @Test func duplicateDirectoryPageNeverBecomesACompleteListing() async throws {
        let session = FakeSMBReadSession()
        let entry = SMBFileInfo(name: "song.flac", isDirectory: false, isSymbolicLink: false, size: 123, modified: nil)
        await session.setEntries([entry, entry])
        await #expect(throws: SMBDriveError.invalidResponse) { try await makeDrive(session).list("/") }
    }

    @Test func boundsAreCheckedBeforeAllocatingOrContactingServer() async throws {
        let session = FakeSMBReadSession()
        let drive = try makeDrive(session)
        await #expect(throws: RemoteDriveError.tooLarge) { try await drive.read("song.flac", range: -1..<10) }
        await #expect(throws: RemoteDriveError.tooLarge) { try await drive.read("song.flac", range: 0..<(SMBDrive.maximumReadBytes + 1)) }
        await #expect(throws: RemoteDriveError.tooLarge) { try await drive.download("cover.jpg", maxBytes: -1) }
        #expect(try await drive.read("song.flac", range: 0..<0).isEmpty)
        #expect(await session.paths.isEmpty)
    }

    @Test func boundedReadAllowsEOFButRejectsOversizedTransportResponse() async throws {
        let session = FakeSMBReadSession()
        await session.setData(Data([1, 2, 3]))
        let drive = try makeDrive(session)
        #expect(try await drive.read("song.flac", range: 1..<20) == Data([2, 3]))
        await session.setOversized(true)
        await #expect(throws: SMBDriveError.invalidResponse) { try await drive.read("song.flac", range: 0..<1) }
    }

    @Test func artworkDownloadRejectsTruncationAndMutation() async throws {
        let session = FakeSMBReadSession()
        await session.setData(Data([1, 2, 3, 4]))
        let drive = try makeDrive(session)
        #expect(try await drive.download("cover.jpg", maxBytes: 4) == Data([1, 2, 3, 4]))
        await #expect(throws: RemoteDriveError.tooLarge) { try await drive.download("cover.jpg", maxBytes: 3) }
        await session.setReportedSize(8)
        await #expect(throws: SMBDriveError.invalidResponse) { try await drive.download("cover.jpg", maxBytes: 8) }
        await session.setReportedSize(nil)
        await session.setChangingMetadata(true)
        await #expect(throws: SMBDriveError.invalidResponse) { try await drive.download("cover.jpg", maxBytes: 8) }
    }

    @Test func cancellationDiscardsLateBytes() async throws {
        let session = FakeSMBReadSession()
        await session.setData(Data([1]))
        await session.setSuspended(true)
        let drive = try makeDrive(session)
        let task = Task { try await drive.read("song.flac", range: 0..<1) }
        while await !session.isWaiting { await Task.yield() }
        task.cancel()
        await session.resumeRead()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    #if canImport(CGumboSMB)
    @Test func protocolPolicyRejectsGuestAnonymousUnsignedAndUnencryptedData() {
        #expect(gumbo_smb2_validate_session(0) == 0)
        #expect(gumbo_smb2_validate_session(UInt16(SMB2_SESSION_FLAG_IS_GUEST)) != 0)
        #expect(gumbo_smb2_validate_session(UInt16(SMB2_SESSION_FLAG_IS_NULL)) != 0)
        #expect(gumbo_smb2_validate_session(UInt16(SMB2_SESSION_FLAG_IS_ENCRYPT_DATA)) == 0)
        #expect(gumbo_smb2_validate_packet(0, 1, UInt16(SMB2_READ.rawValue), 0, 0, 0) != 0)
        #expect(gumbo_smb2_validate_packet(0, 1, UInt16(SMB2_READ.rawValue), 0, UInt32(SMB2_FLAGS_SIGNED), 0) == 0)
        #expect(gumbo_smb2_validate_packet(1, 1, UInt16(SMB2_READ.rawValue), 0, UInt32(SMB2_FLAGS_SIGNED), 0) != 0)
        #expect(gumbo_smb2_validate_packet(1, 1, UInt16(SMB2_READ.rawValue), 1, 0, 0) == 0)
        #expect(gumbo_smb2_validate_packet(1, 1, UInt16(SMB2_TREE_CONNECT.rawValue), 0, UInt32(SMB2_FLAGS_SIGNED), 0) != 0)
        // Negotiation is exempt; final session setup has its own signed/guest checks.
        #expect(gumbo_smb2_validate_packet(1, 1, UInt16(SMB2_NEGOTIATE.rawValue), 0, 0, 0) == 0)
        #expect(gumbo_smb2_validate_packet(0, 1, UInt16(SMB2_READ.rawValue), 0, 0, UInt32(SMB2_STATUS_PENDING)) == 0)
    }

    @Test func directoryBudgetStopsBeforeUnboundedAllocationOrPagination() {
        #expect(gumbo_smb2_directory_budget(100_000, 4096, 64 * 1024 * 1024, 59) == 0)
        #expect(gumbo_smb2_directory_budget(100_001, 1, 80, 0) != 0)
        #expect(gumbo_smb2_directory_budget(1, 4097, 80, 0) != 0)
        #expect(gumbo_smb2_directory_budget(1, 1, 64 * 1024 * 1024 + 1, 0) != 0)
        #expect(gumbo_smb2_directory_budget(1, 1, 80, 60) != 0)
    }
    #endif

    private func makeDrive(_ session: FakeSMBReadSession) throws -> SMBDrive {
        let settings = try SMBConnectionSettings(endpoint: URL(string: "smb://nas.local")!, share: "Music", account: "sam", security: .encrypted)
        return SMBDrive(settings: settings, sourceID: "smb-fixture-account", session: session)
    }
}

private actor FakeSMBReadSession: SMBReadSession {
    var paths: [String] = []
    private var entries: [SMBFileInfo] = []
    private var data = Data()
    private var reportedSize: Int64?
    private var oversized = false
    private var changingMetadata = false
    private var metadataReads = 0
    private var suspended = false
    private var failure: SMBDriveError?
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func setEntries(_ entries: [SMBFileInfo]) { self.entries = entries }
    func setData(_ data: Data) { self.data = data }
    func setOversized(_ value: Bool) { oversized = value }
    func setReportedSize(_ size: Int64?) { reportedSize = size }
    func setChangingMetadata(_ value: Bool) { changingMetadata = value }
    func setSuspended(_ value: Bool) { suspended = value }
    func setFailure(_ error: SMBDriveError?) { failure = error }
    func resumeRead() { waiter?.resume(); waiter = nil }
    func connect() async throws {}
    func disconnect() async {}
    func list(_ path: String) async throws -> [SMBFileInfo] {
        paths.append(path)
        if let failure { throw failure }
        return entries
    }
    func info(_ path: String) async throws -> SMBFileInfo {
        paths.append(path)
        if let failure { throw failure }
        metadataReads += 1
        return .init(name: path, isDirectory: false, isSymbolicLink: false, size: reportedSize ?? Int64(data.count),
                     modified: Date(timeIntervalSince1970: changingMetadata ? Double(metadataReads) : 1))
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        paths.append(path)
        if suspended { await withCheckedContinuation { waiter = $0 } }
        if oversized { return Data(repeating: 0, count: Int(range.count) + 1) }
        let lower = min(Int(range.lowerBound), data.count)
        let upper = min(Int(range.upperBound), data.count)
        return data.subdata(in: lower..<upper)
    }
}

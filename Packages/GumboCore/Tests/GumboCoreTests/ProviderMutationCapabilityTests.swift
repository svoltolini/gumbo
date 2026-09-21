import Foundation
import Testing
@testable import GumboCore

private actor CapabilityDrive: WritableRemoteDrive {
    nonisolated let id = "capability-fixture"
    nonisolated let displayName = "Fixture"
    nonisolated let capabilities: RemoteCapabilities
    var mutations = 0
    init(_ capabilities: RemoteCapabilities = [.read, .ranges]) { self.capabilities = capabilities }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func info(_ path: String) async throws -> RemoteEntry { .init(path: path, name: "song.mp3", isDirectory: false, size: 0, modified: .distantPast) }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { Data() }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { Data() }
    nonisolated func streamURL(for path: String) -> URL? { nil }
    func upload(_ file: URL, toFolder folder: String, name: String, modified: Date?) async throws { mutations += 1 }
    func rename(_ path: String, to name: String) async throws { mutations += 1 }
    func delete(_ path: String) async throws { mutations += 1 }
}

@Suite @MainActor struct ProviderMutationCapabilityTests {
    private func track() -> Track { .init(id: "song", albumID: "album", title: "Song", index: 0, number: 1, disc: 1, duration: 0, codec: "mp3", fileSize: 0, path: "/music/song.mp3", format: "MP3", isEnriched: true) }
    private func catalogue(_ drive: CapabilityDrive) -> Catalogue {
        let album = Album(id: "album", title: "Album", artist: "Artist", year: 2026, genre: "", tracks: [track()], colorA: "#000000", colorB: "#000000", addedRank: 0, folderTitle: "Album", folderArtist: "Artist")
        return Catalogue(serverName: "Fixture", albums: [album], indexedAt: .now, rootPath: "/music", driveID: drive.id)
    }

    @Test func readOnlyConformanceCannotWriteReplaceOrDelete() async throws {
        let drive = CapabilityDrive()
        let track = track()
        let report = await MetadataWriter().write(.init(genre: "Rock"), to: [track], drive: drive)
        #expect(report.written.isEmpty && report.failures.count == 1)
        await #expect(throws: RemoteWriteError.unsupported) {
            try await drive.replaceFile(at: "/music/song.mp3", with: URL(fileURLWithPath: "/unused"), expectedSize: 0, modified: nil)
        }
        let finding = await MusicFileInspector.inspect(track, drive: drive)
        #expect(finding.condition == .damaged && !finding.canDelete)
        await #expect(throws: RemoteWriteError.unsupported) {
            try await MusicFileInspector.deleteReviewed(finding, drive: drive, authorized: { true })
        }
        #expect(await drive.mutations == 0)
    }

    @Test func defaultHelperConfigurationEnablesTagsButNeverDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "ProviderCapabilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileStore(directory: directory, defaults: defaults)
        #expect(profiles.activate(try #require(profiles.owner)))
        let drive = CapabilityDrive()
        let library = LibraryStore()
        library.profiles = profiles
        library.fileDeletionConnectionTokenProvider = { UUID() }
        library.replace(with: catalogue(drive), drive: drive)
        #expect(library.canInspectFiles)
        #expect(!library.canWriteTags && !library.canDeleteFiles && !library.canDeleteAlbums)
        library.tagServiceConfiguration = .init(endpoint: URL(string: "https://helper.example")!, sourceID: drive.id, libraryRoot: "/music")
        #expect(library.canWriteTags && library.canMaintainFiles)
        #expect(!library.canDeleteFiles && !library.canDeleteAlbums)
        await #expect(throws: AlbumDeletionError.unavailable) { _ = try await library.prepareAlbumDeletion(library.catalogue.albums[0]) }
        let finding = await MusicFileInspector.inspect(track(), drive: drive)
        #expect(await library.deleteReviewedFiles([finding]).deleted.isEmpty)
        #expect(await drive.mutations == 0)
        let member = try #require(profiles.create(name: "Listener", avatar: .random(), pin: nil))
        #expect(profiles.activate(member))
        #expect(library.canInspectFiles)
        #expect(library.activeTagService == nil && !library.canWriteTags)
        let denied = await library.writeTags(.init(genre: "Rock"), to: library.tracks)
        #expect(denied.written.isEmpty && denied.failures.count == 1)
        #expect(await drive.mutations == 0)
        #expect(profiles.activate(try #require(profiles.owner)))
        library.tagServiceConfiguration = .init(endpoint: URL(string: "https://helper.example")!, sourceID: drive.id, libraryRoot: "/other")
        #expect(!library.canWriteTags)
    }

    @Test func everyReplacementPrimitiveMustBeAdvertised() {
        let required: [RemoteCapabilities] = [.read, .ranges, .upload, .rename, .delete, .replace]
        let all = required.reduce(RemoteCapabilities()) { $0.union($1) }
        #expect(all.supportsTagReplacement)
        #expect(!all.contains(.conditionalReplace))
        for capability in required { #expect(!all.subtracting(capability).supportsTagReplacement) }
    }
}

actor PartialDownloadDrive: RemoteFileDrive {
    enum Mode: Sendable { case short, oversized, empty, changed, cancelled }
    nonisolated let id = "partial-download"
    nonisolated let displayName = "Fixture"
    let bytes = Data((0..<41).map(UInt8.init))
    let mode: Mode
    var infoCount = 0
    init(_ mode: Mode) { self.mode = mode }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func info(_ path: String) async throws -> RemoteEntry {
        infoCount += 1
        return .init(path: path, name: "song.mp3", isDirectory: false, size: Int64(bytes.count), modified: Date(timeIntervalSince1970: mode == .changed && infoCount > 1 ? 2 : 1))
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        if mode == .cancelled { throw CancellationError() }
        if mode == .oversized { return Data(repeating: 0, count: Int(range.count) + 1) }
        if mode == .empty || range.lowerBound >= bytes.count { return Data() }
        return bytes.subdata(in: Int(range.lowerBound)..<min(Int(range.lowerBound) + 3, Int(range.upperBound), bytes.count))
    }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { bytes }
    nonisolated func streamURL(for path: String) -> URL? { nil }
}

@Suite struct ProviderDefaultDownloadTests {
    @Test func shortReadsContinueUntilVerifiedEndAndRespectMaximum() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "download.mp3")
        let drive = PartialDownloadDrive(.short)
        try await drive.downloadFile("/song.mp3", to: destination, maxBytes: 41)
        #expect(try Data(contentsOf: destination) == drive.bytes)
        try Data("replace me only on success".utf8).write(to: destination)
        try await drive.downloadFile("/song.mp3", to: destination, maxBytes: 41)
        #expect(try Data(contentsOf: destination) == drive.bytes)
        await #expect(throws: RemoteDriveError.tooLarge) { try await drive.downloadFile("/song.mp3", to: destination, maxBytes: 40) }
        #expect(try Data(contentsOf: destination) == drive.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["download.mp3"])
    }

    @Test(arguments: [PartialDownloadDrive.Mode.oversized, .empty, .changed, .cancelled])
    func failedTransfersPreserveExistingDestinationAndLeaveNoPartial(_ mode: PartialDownloadDrive.Mode) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "download.mp3")
        let sentinel = Data("keep existing file".utf8)
        try sentinel.write(to: destination)
        let drive = PartialDownloadDrive(mode)
        await #expect(throws: (any Error).self) { try await drive.downloadFile("/song.mp3", to: destination, maxBytes: Int64.max) }
        #expect(try Data(contentsOf: destination) == sentinel)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["download.mp3"])
    }
}

import CryptoKit
import Foundation
import Testing
@testable import GumboCore

private actor HelperFileFixture: RemoteFileDrive {
    nonisolated let id = "helper-deletion-fixture"
    nonisolated let displayName = "Read-only fixture provider"
    var bytes: Data
    init(bytes: Data = Data("generated song fixture".utf8)) { self.bytes = bytes }
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func info(_ path: String) async throws -> RemoteEntry {
        RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: false, size: Int64(bytes.count), modified: modified)
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { bytes }
    func downloadFile(_ path: String, to destination: URL, maxBytes: Int64) async throws { throw RemoteWriteError.unsupported }
    nonisolated func streamURL(for path: String) -> URL? { nil }
    func replaceWithSameSize() { bytes[0] ^= 1 }
    func expected() -> RemoteTagService.Expected {
        .init(size: Int64(bytes.count), mtimeNs: 1_700_000_000_000_000_000,
              sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}

private actor HelperServiceFixture: ReviewedDeletionService {
    let expected: RemoteTagService.Expected
    let mode: String
    var submissions = 0
    var statusReads = 0
    var cancellations = 0
    var lastID: UUID?
    var lastPath: String?
    init(expected: RemoteTagService.Expected, mode: String = "success") { self.expected = expected; self.mode = mode }
    func reviewDeletion(path: String) async throws -> RemoteTagService.DeletionReview {
        try decode(["version": 1, "path": path, "expected": stamp])
    }
    private var stamp: [String: Any] { ["size": expected.size, "mtimeNs": expected.mtimeNs, "sha256": expected.sha256] }
    private func decode<T: Decodable>(_ value: [String: Any]) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value)) }
    private func job(_ identifier: UUID, status: String = "completed", fileStatus: String = "deleted") throws -> RemoteTagService.Job {
        try decode(["version": 1, "jobID": identifier.uuidString, "operation": mode == "wrongOperation" ? "tags" : "delete",
                    "dryRun": mode == "dryRun", "status": status,
                    "files": [["path": lastPath ?? "song.wav", "status": fileStatus, "before": stamp]]])
    }
    func inspectionRead(path: String, expected: RemoteTagService.Expected, range: Range<Int64>) async throws -> Data {
        #expect(expected == self.expected)
        return Data(repeating: 0, count: range.count)
    }
    func submitDeletion(jobID: UUID, files: [RemoteTagService.Deletion]) async throws -> RemoteTagService.Job {
        submissions += 1; lastID = jobID; lastPath = files[0].path
        #expect(files.count == 1 && files[0].expected == expected)
        if mode == "lostAck" { throw RemoteTagService.Error.unavailable }
        if mode == "busy" { throw RemoteTagService.Error.service(code: "busy", message: "The helper's edit queue is full. Try later.") }
        if mode == "queued" { return try job(jobID, status: "queued", fileStatus: "pending") }
        return try job(jobID, status: mode == "unconfirmed" ? "partial" : "completed", fileStatus: mode == "unconfirmed" ? "unconfirmed" : "deleted")
    }
    func status(jobID: UUID) async throws -> RemoteTagService.Job {
        statusReads += 1
        #expect(jobID == lastID)
        return try job(jobID)
    }
    func cancel(jobID: UUID) async throws -> RemoteTagService.Job {
        cancellations += 1
        #expect(jobID == lastID)
        // A deletion accepted just before Stop remains a confirmed success.
        return try job(jobID)
    }
}

@Suite struct HelperDeletionTests {
    private func configuration(_ enabled: Bool = true, endpoint: String = "https://helper.example") -> TagServiceConfiguration {
        .init(endpoint: URL(string: endpoint)!, sourceID: "helper-deletion-fixture", libraryRoot: "/music", allowsReviewedDeletion: enabled)
    }

    @Test func legacyConfigurationDoesNotEnableDeletionOrChangeTokenAccount() throws {
        let old = Data(#"{"endpoint":"https://helper.example","sourceID":"helper-deletion-fixture","libraryRoot":"/music"}"#.utf8)
        let value = try JSONDecoder().decode(TagServiceConfiguration.self, from: old)
        #expect(value.allowsReviewedDeletion != true)
        #expect(value.keychainAccount == configuration().keychainAccount)
    }

    @Test func wrongMountAndChangedContentAreRejectedWithoutSubmission() async throws {
        let base = HelperFileFixture()
        let service = HelperServiceFixture(expected: await base.expected())
        let drive = HelperDeletionDrive(base: base, configuration: configuration(), service: service)
        let review = try await drive.reviewDeletion("/music/song.wav")
        #expect(review == (try await drive.reviewDeletion("/music/song.wav")))
        await base.replaceWithSameSize()
        await #expect(throws: RemoteWriteError.changed) { try await drive.reviewDeletion("/music/song.wav") }
        await #expect(throws: RemoteWriteError.changed) { try await drive.deleteReviewed(review) { true } }
        #expect(await service.submissions == 0)
    }

    @Test func reviewCannotBeUsedWithAnotherHelperOrRevokedAuthority() async throws {
        let base = HelperFileFixture()
        let service = HelperServiceFixture(expected: await base.expected())
        let drive = HelperDeletionDrive(base: base, configuration: configuration(), service: service)
        let review = try await drive.reviewDeletion("/music/song.wav")
        let other = HelperDeletionDrive(base: base, configuration: configuration(endpoint: "https://other.example"), service: service)
        await #expect(throws: RemoteWriteError.changed) { try await other.deleteReviewed(review) { true } }
        await #expect(throws: CancellationError.self) { try await drive.deleteReviewed(review) { false } }
        let disabled = HelperDeletionDrive(base: base, configuration: configuration(false), service: service)
        await #expect(throws: RemoteWriteError.unsupported) { try await disabled.reviewDeletion("/music/song.wav") }
        #expect(await service.submissions == 0)
    }

    @Test(arguments: ["success", "lostAck"]) func confirmedResultAndLostReplyUseOneDurableJob(_ mode: String) async throws {
        let base = HelperFileFixture()
        let service = HelperServiceFixture(expected: await base.expected(), mode: mode)
        let drive = HelperDeletionDrive(base: base, configuration: configuration(), service: service)
        let review = try await drive.reviewDeletion("/music/song.wav")
        try await drive.deleteReviewed(review) { true }
        #expect(await service.submissions == 1)
        #expect(await service.statusReads == (mode == "lostAck" ? 1 : 0))
    }

    @Test func structuredRejectionIsReportedWithoutPollingAJobThatWasNeverQueued() async throws {
        let base = HelperFileFixture()
        let service = HelperServiceFixture(expected: await base.expected(), mode: "busy")
        let drive = HelperDeletionDrive(base: base, configuration: configuration(), service: service)
        let review = try await drive.reviewDeletion("/music/song.wav")
        await #expect(throws: RemoteTagService.Error.service(code: "busy", message: "The helper's edit queue is full. Try later.")) {
            try await drive.deleteReviewed(review) { true }
        }
        #expect(await service.submissions == 1)
        #expect(await service.statusReads == 0)
        #expect(await service.cancellations == 0)
    }

    @Test(arguments: ["unconfirmed", "wrongOperation", "dryRun"]) func ambiguousResultNeverCountsAsDeleted(_ mode: String) async throws {
        let base = HelperFileFixture()
        let service = HelperServiceFixture(expected: await base.expected(), mode: mode)
        let drive = HelperDeletionDrive(base: base, configuration: configuration(), service: service)
        let review = try await drive.reviewDeletion("/music/song.wav")
        do {
            try await drive.deleteReviewed(review) { true }
            Issue.record("Unconfirmed deletion was reported as success")
        } catch let error as RemoteWriteError {
            #expect(error.isDeletionUnconfirmed)
            if case .helperDeletionUnconfirmed(let identifier) = error { #expect(identifier == (await service.lastID)) }
            else { Issue.record("The original helper job identifier was lost") }
        }
        #expect(await service.submissions == 1)
    }

    @Test @MainActor func revokeWhileQueuedStillCollectsConfirmedDeletion() async throws {
        let base = HelperFileFixture()
        let service = HelperServiceFixture(expected: await base.expected(), mode: "queued")
        let drive = HelperDeletionDrive(base: base, configuration: configuration(), service: service)
        let review = try await drive.reviewDeletion("/music/song.wav")
        var checks = 0
        try await drive.deleteReviewed(review) { checks += 1; return checks == 1 }
        #expect(await service.cancellations == 1)
        #expect(await service.submissions == 1)
    }

    @Test func helperInspectionProducesAnActualWitnessAndClosesItsSnapshot() async throws {
        let base = HelperFileFixture(bytes: Data())
        let service = HelperServiceFixture(expected: await base.expected())
        let drive = HelperDeletionDrive(base: base, configuration: configuration(), service: service)
        let track = Track(id: "empty", albumID: "fixture", title: "Empty fixture", index: 0, number: 1, disc: 1,
                          duration: 0, codec: "wav", fileSize: 0, path: "/music/empty.wav", format: "WAV", isEnriched: true)
        let finding = await MusicFileInspector.inspect(track, drive: drive)
        #expect(finding.condition == .damaged && finding.canDelete)
        try await MusicFileInspector.deleteReviewed(finding, drive: drive) { true }
        #expect(await service.submissions == 1)
        let snapshot = try await drive.inspectionSnapshot("/music/empty.wav")
        try await snapshot.validate()
        #expect(try await snapshot.read(0..<0).isEmpty)
        await snapshot.close()
        await #expect(throws: RemoteWriteError.changed) { try await snapshot.validate() }
        await #expect(throws: RemoteWriteError.changed) { _ = try await snapshot.read(0..<0) }
    }

    @Test @MainActor func libraryRequiresOptInAndDiscardsReviewWhenMappingChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-helper-review-\(UUID())")
        let suite = "GumboHelperDeletionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileStore(directory: directory, defaults: defaults)
        #expect(profiles.activate(try #require(profiles.owner)))
        let base = HelperFileFixture()
        let service = HelperServiceFixture(expected: await base.expected())
        let library = LibraryStore()
        library.profiles = profiles
        let connection = UUID()
        library.fileDeletionConnectionTokenProvider = { connection }
        library.deletionServiceFactory = { _ in service }
        let track = Track(id: "song", albumID: "album", title: "Generated song", index: 0, number: 1, disc: 1,
                          duration: 1, codec: "wav", fileSize: nil, path: "/music/song.wav", format: "WAV", isEnriched: true)
        let album = Album(id: "album", title: "Generated album", artist: "Fixture", year: 2026, genre: "Test",
                          tracks: [track], colorA: "#000000", colorB: "#000000", addedRank: 0, folderPath: "/music", folderTitle: "Generated album", folderArtist: "Fixture")
        library.replace(with: Catalogue(serverName: "Fixture", albums: [album], indexedAt: .now, rootPath: "/music", driveID: base.id), drive: base)
        library.tagServiceConfiguration = configuration(false)
        #expect(!library.canDeleteAlbums)
        library.tagServiceConfiguration = configuration()
        #expect(library.canDeleteAlbums)
        #expect(library.canDeleteInspectedFiles)
        let review = try await library.prepareAlbumDeletion(album)
        library.tagServiceConfiguration = configuration(endpoint: "https://different.example")
        #expect(!library.canDeleteAlbum(using: review))
        let report = await library.deleteAlbum(review)
        #expect(report.deleted.isEmpty && !report.failures.isEmpty)
        #expect(await service.submissions == 0)
        #expect(library.catalogue.albums.count == 1)
        library.tagServiceConfiguration = configuration()
        library.persistDeletedAlbumCatalogue = { _ in true }
        var removals: Set<String> = []
        library.onServerTracksDeleted = { source, ids in
            #expect(source == base.id)
            removals.formUnion(ids)
        }
        let fresh = try await library.prepareAlbumDeletion(album)
        let confirmed = await library.deleteAlbum(fresh)
        #expect(confirmed.deleted.map(\.id) == ["song"] && confirmed.failures.isEmpty)
        #expect(removals == ["song"] && library.catalogue.albums.isEmpty)
        #expect(await service.submissions == 1)
    }
}

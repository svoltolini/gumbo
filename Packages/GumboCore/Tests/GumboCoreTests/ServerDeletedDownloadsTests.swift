import Foundation
import Testing
@testable import GumboCore

@MainActor
private final class DeletedDownloadHarness {
    let directory: URL
    private(set) var manager: DownloadManager!
    private(set) var delegate: DownloadDelegate!
    private(set) var session: URLSession!
    private var restoration: (@Sendable ([URLSessionTask]) -> Void)?
    var currentSource = "nas-a"

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "GumboDeletedDownloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        open()
    }

    func open() {
        delegate = DownloadDelegate()
        manager = DownloadManager(directory: directory, configuration: .ephemeral, delegate: delegate,
            restoreTasks: { [weak self] session, completion in
                self?.session = session
                self?.restoration = completion
            }, resumeTask: { _ in })
        manager.driveIDProvider = { [weak self] in self?.currentSource ?? "" }
        manager.activeProfileID = "listener"
    }

    func restore(_ jobs: [DownloadJob] = []) async throws {
        restoration?(jobs.map(task))
        restoration = nil
        try await drainDeletionCallbacks()
    }

    func task(_ job: DownloadJob) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: URL(string: "https://nas.example:5001/not-requested")!)
        task.taskDescription = job.encoded
        return task
    }

    func queue(_ owner: DownloadOwner, source: String = "nas-a") throws -> [DownloadJob] {
        manager.download(owner, driveID: source) { _ in URL(string: "https://nas.example:5001/not-requested") }
        struct Intent: Decodable { var jobs: [String: DownloadJob] }
        let intent = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: directory.appending(path: "download-intent.json")))
        return intent.jobs.values.filter { $0.driveID == source }.sorted { $0.trackID < $1.trackID }
    }

    func finish(_ job: DownloadJob) throws {
        let incoming = directory.appending(path: UUID().uuidString)
        try deletionBytes.write(to: incoming)
        delegate.urlSession(session, downloadTask: task(job), didFinishDownloadingTo: incoming)
    }

    func reopen() {
        manager = nil
        session.invalidateAndCancel()
        open()
    }

    func close() {
        manager = nil
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private let deletionBytes = Data(repeating: 0x5A, count: 8192)
private func deletionAlbum(count: Int = 1) -> Album {
    var album = SampleLibrary.catalogue.albums[0]
    album.tracks = album.tracks.prefix(count).map { original in
        var track = original
        track.fileSize = Int64(deletionBytes.count)
        return track
    }
    return album
}
@MainActor private func drainDeletionCallbacks() async throws { try await Task.sleep(for: .milliseconds(30)) }

@Suite(.serialized) @MainActor
struct ServerDeletedDownloadsTests {
    @Test func removesEveryOwnerOfDeletedSourceWhileSameTrackOnOtherNASRemains() async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        try await h.restore()
        let album = deletionAlbum()
        let first = DownloadOwner(album: album, profileID: "listener")
        let second = DownloadOwner(album: album, profileID: "second")
        let a = try #require(h.queue(first).first)
        _ = try h.queue(second)
        let b = try #require(h.queue(first, source: "nas-b").first)
        try h.finish(a)
        try h.finish(b)
        try await drainDeletionCallbacks()
        #expect(h.manager.records[a.cacheKey]?.owners == [first.id, second.id])
        h.manager.reconcile(albums: [album.id], playlists: [], driveID: "nas-a", album: { _ in album }, playlist: { _ in nil })
        #expect(h.manager.isRestored(first, driveID: "nas-a"))
        var notifications: [String] = []
        h.manager.onMembershipChanged = { source, _, _ in notifications.append(source) }
        // Cleanup uses its supplied source even if the person switched servers during NAS deletion.
        h.currentSource = "nas-b"
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [album.tracks[0].id])
        #expect(h.manager.records[a.cacheKey] == nil)
        #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: a.fileName).path))
        #expect(h.manager.records[b.cacheKey]?.owners == [first.id])
        #expect(try Data(contentsOf: h.directory.appending(path: b.fileName)) == deletionBytes)
        #expect(h.manager.localURL(for: album.tracks[0]) != nil)
        #expect(h.manager.downloadMembership(driveID: "nas-a").albums.isEmpty)
        #expect(!h.manager.isRestored(first, driveID: "nas-a"))
        #expect(h.manager.downloadMembership(driveID: "nas-b").albums == [album.id])
        #expect(notifications == ["nas-a"])
    }

    @Test func partialAlbumDeletionKeepsSurvivingDownloadAndRequestProgress() async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        try await h.restore()
        let album = deletionAlbum(count: 2)
        let owner = DownloadOwner(album: album, profileID: "listener")
        let jobs = try h.queue(owner)
        let removed = try #require(jobs.first)
        let kept = try #require(jobs.last)
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [removed.trackID])
        #expect(h.manager.pendingByOwner[owner.id] == [kept.cacheKey])
        #expect(h.manager.progressSnapshot(ownerID: owner.id, driveID: "nas-a")?.total == 1)
        try h.finish(removed)
        try h.finish(kept)
        try await drainDeletionCallbacks()
        #expect(h.manager.records[removed.cacheKey] == nil)
        #expect(h.manager.records[kept.cacheKey]?.owners == [owner.id])
        #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: removed.incomingFileName).path))
        #expect(h.manager.downloadMembership(driveID: "nas-a").albums == [album.id])
    }

    @Test(arguments: [false, true])
    func deletionBeforeOrAfterRestorationRejectsLateCompletionAndSurvivesRelaunch(restored: Bool) async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        try await h.restore()
        let album = deletionAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        let job = try #require(h.queue(owner).first)
        h.reopen()
        if restored { try await h.restore([job]) }
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [job.trackID])
        try h.finish(job)
        if !restored { try await h.restore([job]) }
        try await drainDeletionCallbacks()
        #expect(h.manager.records.isEmpty)
        #expect(h.manager.pendingByOwner.isEmpty)
        #expect(h.manager.listedOwnerIDs.isEmpty)
        h.reopen()
        try await h.restore([job])
        try h.finish(job)
        try await drainDeletionCallbacks()
        #expect(h.manager.records.isEmpty)
        #expect(h.manager.pendingByOwner.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: job.incomingFileName).path))
    }

    @Test func unknownLegacyCompletionCannotResurrectConfirmedDeletionAfterRelaunch() async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        let album = deletionAlbum()
        let track = album.tracks[0]
        let legacy = DownloadJob(ownerID: DownloadOwner.albumPrefix + album.id, trackID: track.id, driveID: "nas-a",
            fileName: DownloadManager.fileName(for: track, driveID: "nas-a"), expectedBytes: Int64(deletionBytes.count),
            ownerTitle: album.title, ownerSubtitle: album.artist, trackTitle: track.title, ownerTrackCount: 1)
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [track.id])
        h.reopen()
        try h.finish(legacy)
        try await h.restore([legacy])
        #expect(h.manager.records.isEmpty)
        #expect(h.manager.pendingByOwner.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: legacy.incomingFileName).path))
    }

    @Test func explicitlyDownloadingAFileRestoredToNASUsesFreshAttempt() async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        try await h.restore()
        let album = deletionAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        let old = try #require(h.queue(owner).first)
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [old.trackID])
        let new = try #require(h.queue(owner).first)
        #expect(new.attemptID != old.attemptID)
        try h.finish(old)
        try h.finish(new)
        try await drainDeletionCallbacks()
        #expect(h.manager.records[new.cacheKey]?.fileName == new.fileName)
        h.reopen()
        try await h.restore()
        #expect(h.manager.state(for: owner) == .downloaded)
        try h.finish(old)
        try await drainDeletionCallbacks()
        #expect(h.manager.records[new.cacheKey]?.fileName == new.fileName)
    }

    @Test(arguments: [false, true])
    func committedDeletionIntentRejectsAStaleManifestAfterCrash(repeatedDeletion: Bool) async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        try await h.restore()
        let album = deletionAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        var previous = try #require(h.queue(owner).first)
        try h.finish(previous)
        try await drainDeletionCallbacks()
        if repeatedDeletion {
            h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [previous.trackID])
            previous = try #require(h.queue(owner).first)
            try h.finish(previous)
            try await drainDeletionCallbacks()
            #expect(h.manager.records[previous.cacheKey]?.serverDeletionEpoch != nil)
        }
        let manifestURL = h.directory.appending(path: "downloads.json")
        let staleManifest = try Data(contentsOf: manifestURL)
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [previous.trackID])
        // Model termination after the deletion intent committed but before the old manifest
        // and physical file were removed. Only the authoritative intent is the newer version.
        try staleManifest.write(to: manifestURL, options: .atomic)
        try deletionBytes.write(to: h.directory.appending(path: previous.fileName))
        h.reopen()
        try await h.restore()
        #expect(h.manager.records[previous.cacheKey] == nil)
        #expect(h.manager.localURL(for: album.tracks[0]) == nil)
        #expect(h.manager.downloadMembership(driveID: "nas-a").albums.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: previous.fileName).path))
        let fresh = try #require(h.queue(owner).first)
        try h.finish(fresh)
        try await drainDeletionCallbacks()
        h.reopen()
        try await h.restore()
        #expect(h.manager.state(for: owner) == .downloaded)
        #expect(h.manager.records[fresh.cacheKey]?.fileName == fresh.fileName)
    }

    @Test func crashRecoveryPreservesAnUnrelatedSourceSharingALegacyFileName() async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        try await h.restore()
        let track = deletionAlbum().tracks[0]
        let name = "legacy-shared.flac"
        let records = ["nas-a", "nas-b"].map { source in
            DownloadRecord(trackID: track.id, driveID: source, fileName: name, bytes: Int64(deletionBytes.count),
                           owners: ["profile:listener|album:legacy"])
        }
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [track.id])
        try JSONEncoder().encode(records).write(to: h.directory.appending(path: "downloads.json"))
        try deletionBytes.write(to: h.directory.appending(path: name))
        h.reopen()
        try await h.restore()
        #expect(h.manager.records.count == 1)
        #expect(h.manager.records.values.first?.driveID == "nas-b")
        #expect(try Data(contentsOf: h.directory.appending(path: name)) == deletionBytes)
    }

    @Test func removesExactOrphanedCopiesWithoutSweepingUnrelatedFiles() async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        try await h.restore()
        let track = deletionAlbum().tracks[0]
        let nameA = DownloadManager.fileName(for: track, driveID: "nas-a")
        let nameB = DownloadManager.fileName(for: track, driveID: "nas-b")
        for name in [nameA, "old-attempt-" + nameA, nameB, "incoming-unrelated", "unrelated.mp3"] {
            try deletionBytes.write(to: h.directory.appending(path: name))
        }
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [track.id])
        #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: nameA).path))
        #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: "old-attempt-" + nameA).path))
        for name in [nameB, "incoming-unrelated", "unrelated.mp3"] {
            #expect(FileManager.default.fileExists(atPath: h.directory.appending(path: name).path))
        }
    }

    @Test func legacyFileNameSharedByAnotherSourceIsNotDeleted() async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        let track = deletionAlbum().tracks[0]
        let sharedFile = h.directory.appending(path: "legacy-shared.flac")
        try deletionBytes.write(to: sharedFile)
        let records = ["nas-a", "nas-b"].map { source in
            DownloadRecord(trackID: track.id, driveID: source, fileName: sharedFile.lastPathComponent,
                           bytes: Int64(deletionBytes.count), owners: ["profile:listener|album:legacy"])
        }
        try JSONEncoder().encode(records).write(to: h.directory.appending(path: "downloads.json"))
        h.reopen()
        try await h.restore()
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [track.id])
        #expect(h.manager.records.count == 1)
        #expect(h.manager.records.values.first?.driveID == "nas-b")
        #expect(try Data(contentsOf: sharedFile) == deletionBytes)
    }

    @Test func malformedLegacyFileNameCannotDeleteDirectoriesOrBookkeeping() async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        let nested = h.directory.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let sentinel = nested.appending(path: "keep.txt")
        try deletionBytes.write(to: sentinel)
        let names = [".", "..", "nested", "download-intent.json"]
        let records = names.enumerated().map { index, name in
            DownloadRecord(trackID: "bad-\(index)", driveID: "nas-a", fileName: name,
                           bytes: 1, owners: ["profile:listener|album:legacy"])
        }
        try JSONEncoder().encode(records).write(to: h.directory.appending(path: "downloads.json"))
        h.reopen()
        try await h.restore()
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: Set(records.map(\.trackID)))
        #expect(try Data(contentsOf: sentinel) == deletionBytes)
        #expect(FileManager.default.fileExists(atPath: h.directory.appending(path: "downloads.json").path))
        #expect(FileManager.default.fileExists(atPath: h.directory.appending(path: "download-intent.json").path))
    }

    @Test func removingAnotherProfilesTracksDoesNotPublishCurrentProfileMembership() async throws {
        let h = try DeletedDownloadHarness()
        defer { h.close() }
        try await h.restore()
        let album = deletionAlbum()
        let owner = DownloadOwner(album: album, profileID: "second")
        let job = try #require(h.queue(owner).first)
        var notified = false
        h.manager.onMembershipChanged = { _, _, _ in notified = true }
        h.manager.removeServerTracks(sourceID: "nas-a", trackIDs: [job.trackID])
        #expect(!notified)
        #expect(h.manager.pendingByOwner.isEmpty)
    }
}

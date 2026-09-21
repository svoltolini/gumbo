import Foundation
import Testing
@testable import GumboCore

private actor AlbumDeletionDrive: WritableRemoteDrive {
    nonisolated let capabilities: RemoteCapabilities = [.read, .ranges, .delete]
    nonisolated let id = "album-deletion-fixture"
    nonisolated let displayName = "Fixture NAS"
    var entries: [String: RemoteEntry]
    var deleted: [String] = []
    var attempts: [String] = []
    var failPaths: Set<String> = []
    var onInfo: (@Sendable (String) async -> Void)?
    var onDelete: (@Sendable (String) async -> Void)?
    var pendingDelete: CheckedContinuation<Void, Never>?
    var holdDeletes = false

    init(entries: [RemoteEntry]) { self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) }) }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { Array(entries.values) }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { throw RemoteWriteError.unsupported }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { throw RemoteWriteError.unsupported }
    nonisolated func streamURL(for path: String) -> URL? { nil }
    func upload(_ file: URL, toFolder folder: String, name: String, modified: Date?) async throws { throw RemoteWriteError.unsupported }
    func rename(_ path: String, to name: String) async throws { throw RemoteWriteError.unsupported }
    func info(_ path: String) async throws -> RemoteEntry {
        guard let entry = entries[path] else { throw RemoteWriteError.missing }
        if let onInfo { await onInfo(path) }
        return entry
    }
    func delete(_ path: String) async throws {
        attempts.append(path)
        if failPaths.contains(path) { throw RemoteWriteError.readOnly }
        if holdDeletes { await withCheckedContinuation { pendingDelete = $0 } }
        if let onDelete { await onDelete(path) }
        guard entries.removeValue(forKey: path) != nil else { throw RemoteWriteError.missing }
        deleted.append(path)
    }
    func setFailures(_ paths: Set<String>) { failPaths = paths }
    func setInfoHook(_ hook: @escaping @Sendable (String) async -> Void) { onInfo = hook }
    func setDeleteHook(_ hook: @escaping @Sendable (String) async -> Void) { onDelete = hook }
    func setEntry(_ entry: RemoteEntry) { entries[entry.path] = entry }
    func holdNextDelete() { holdDeletes = true }
    func releaseDelete() { holdDeletes = false; pendingDelete?.resume(); pendingDelete = nil }
    var isWaiting: Bool { pendingDelete != nil }
}

@MainActor private final class AlbumDeletionFixture {
    let suite = "GumboAlbumDeletionTests.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-album-delete-\(UUID())")
    let defaults: UserDefaults
    let profiles: ProfileStore
    let library = LibraryStore()
    let drive: AlbumDeletionDrive
    var token: UUID? = UUID()
    var persistenceSucceeds = true
    var savedCatalogues: [Catalogue] = []
    var notifications: [(String, Set<String>)] = []
    let firstPath = "/music/shared/first.flac"
    let secondPath = "/music/shared/second.flac"
    let otherPath = "/music/shared/another-album.flac"
    let artworkPath = "/music/shared/cover.jpg"
    let modified = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        profiles = ProfileStore(directory: directory, defaults: defaults)
        #expect(profiles.activate(try #require(profiles.owner)))
        let paths = [firstPath, secondPath, otherPath, artworkPath]
        drive = AlbumDeletionDrive(entries: paths.map {
            RemoteEntry(path: $0, name: ($0 as NSString).lastPathComponent, isDirectory: false, size: 100, modified: Date(timeIntervalSince1970: 1_700_000_000))
        })
        library.profiles = profiles
        library.fileDeletionConnectionTokenProvider = { [weak self] in self?.token }
        library.persistDeletedAlbumCatalogue = { [weak self] catalogue in
            guard let self else { return false }
            savedCatalogues.append(catalogue)
            return persistenceSucceeds
        }
        library.onServerTracksDeleted = { [weak self] source, ids in self?.notifications.append((source, ids)) }
        installCatalogue()
    }

    func track(_ path: String, albumID: String, index: Int, id: String? = nil) -> Track {
        var value = Track(id: id ?? path, albumID: albumID, title: (path as NSString).lastPathComponent,
                          index: index, number: index + 1, disc: 1, duration: 120, codec: "flac",
                          fileSize: 100, path: path, format: "FLAC", isEnriched: true)
        value.sourceModifiedAt = modified.timeIntervalSince1970
        return value
    }

    func album(_ id: String, paths: [String]) -> Album {
        Album(id: id, title: id, artist: "Fixture Artist", year: 2026, genre: "Test",
              tracks: paths.enumerated().map { track($0.element, albumID: id, index: $0.offset) },
              colorA: "#000000", colorB: "#000000", addedRank: 0, folderPath: "/music/shared",
              folderTitle: id, folderArtist: "Fixture Artist")
    }

    func installCatalogue(paths: [String]? = nil, otherPaths: [String]? = nil, source: String? = nil) {
        let catalogue = Catalogue(serverName: "Fixture NAS", albums: [
            album("Target Album", paths: paths ?? [firstPath, secondPath]),
            album("Other Album", paths: otherPaths ?? [otherPath])
        ], indexedAt: .now, rootPath: "/music", driveID: source ?? drive.id)
        library.replace(with: catalogue, drive: drive)
    }

    var target: Album { library.catalogue.albums.first { $0.id == "Target Album" }! }
    func cleanUp() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
}

@Suite @MainActor struct AlbumDeletionTests {
    @Test func preparationNeverDeletesAndFinalDeletionTouchesOnlyReviewedAudioFiles() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        let request = try await f.library.prepareAlbumDeletion(f.target)
        #expect(request.fileCount == 2)
        #expect(request.tracks.map(\.path) == [f.firstPath, f.secondPath])
        #expect(await f.drive.attempts.isEmpty)
        #expect(f.library.canDeleteAlbum(using: request))
        let report = await f.library.deleteAlbum(request)
        #expect(report.deleted.map(\.id) == [f.firstPath, f.secondPath])
        #expect(report.failures.isEmpty && report.remainingCount == 0 && !report.wasCancelled)
        #expect(await f.drive.deleted == [f.firstPath, f.secondPath])
        #expect(try await f.drive.info(f.otherPath).isDirectory == false)
        #expect(try await f.drive.info(f.artworkPath).isDirectory == false)
        #expect(f.library.catalogue.albums.map(\.id) == ["Other Album"])
        #expect(f.savedCatalogues.count == 2)
        #expect(f.savedCatalogues.last?.trackCount == 1)
        #expect(f.notifications.map(\.0) == [f.drive.id, f.drive.id])
        #expect(f.notifications.flatMap { $0.1 } == [f.firstPath, f.secondPath])
        #expect(f.library.albumDeletionProgress == nil)
        #expect(!f.library.isDeletingFiles)
        #expect(!f.library.canDeleteAlbum(using: request), "A consumed confirmation cannot be reused")
    }

    @Test func profilelessMembersAndLockedOwnersCannotPrepareOrDelete() async throws {
        for kind in ["profileless", "member", "locked"] {
            let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
            let request = try await f.library.prepareAlbumDeletion(f.target)
            switch kind {
            case "profileless": f.library.profiles = nil
            case "member":
                let member = try #require(f.profiles.create(name: "Member", avatar: .random(), pin: nil))
                #expect(f.profiles.activate(member))
            default: f.profiles.lock()
            }
            #expect(!f.library.canDeleteAlbums)
            await #expect(throws: (any Error).self) { try await f.library.prepareAlbumDeletion(f.target) }
            #expect(await f.library.deleteAlbum(request).deleted.isEmpty)
            #expect(await f.drive.attempts.isEmpty)
        }
    }

    @Test func disconnectedScanningAndChangedConnectionTokensInvalidateAReview() async throws {
        for kind in ["disconnected", "scan", "new-login"] {
            let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
            let request = try await f.library.prepareAlbumDeletion(f.target)
            switch kind {
            case "disconnected": f.library.drive = nil
            case "scan": f.token = nil
            default: f.token = UUID()
            }
            #expect(!f.library.canDeleteAlbum(using: request))
            #expect(await f.library.deleteAlbum(request).deleted.isEmpty)
            #expect(await f.drive.attempts.isEmpty)
        }
    }

    @Test func traversalArtworkSharedPathsAndDuplicateTargetsAreNeverPrepared() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        for paths in [["/music/../other/song.flac"], ["/music-other/song.flac"], [f.artworkPath],
                      [f.otherPath], [f.firstPath, f.firstPath], ["/music/shared//song.flac"]] {
            f.installCatalogue(paths: paths)
            await #expect(throws: AlbumDeletionError.self) { try await f.library.prepareAlbumDeletion(f.target) }
        }
        #expect(await f.drive.attempts.isEmpty)
    }

    @Test func duplicateSongIdentityAndUnverifiableRemoteFilesAreRejected() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        var malformed = f.library.catalogue
        malformed.albums[0].tracks[1] = f.track(f.secondPath, albumID: "Target Album", index: 1, id: f.firstPath)
        f.library.replace(with: malformed, drive: f.drive)
        await #expect(throws: AlbumDeletionError.self) { try await f.library.prepareAlbumDeletion(f.target) }
        for kind in ["directory", "unknown-size", "unknown-date", "changed-size"] {
            f.installCatalogue()
            await f.drive.setEntry(RemoteEntry(path: f.firstPath, name: "first.flac", isDirectory: kind == "directory",
                                               size: kind == "unknown-size" ? nil : (kind == "changed-size" ? 101 : 100),
                                               modified: kind == "unknown-date" ? nil : f.modified))
            await #expect(throws: (any Error).self) { try await f.library.prepareAlbumDeletion(f.target) }
            #expect(!f.library.isDeletingFiles)
        }
        #expect(await f.drive.attempts.isEmpty)
    }

    @Test func newReviewsAndReopenedOwnerSessionsInvalidateOldConsent() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        let first = try await f.library.prepareAlbumDeletion(f.target)
        let second = try await f.library.prepareAlbumDeletion(f.target)
        #expect(!f.library.canDeleteAlbum(using: first))
        #expect(f.library.canDeleteAlbum(using: second))
        f.profiles.lock()
        #expect(f.profiles.activate(try #require(f.profiles.owner)))
        #expect(!f.library.canDeleteAlbum(using: second))
        #expect(await f.library.deleteAlbum(second).deleted.isEmpty)
        #expect(await f.drive.attempts.isEmpty)
    }

    @Test func checkingAndDeletingFilesExcludesOtherMaintenanceOperations() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        await f.drive.setInfoHook { _ in
            await MainActor.run {
                #expect(f.library.isDeletingFiles)
                #expect(!f.library.canDeleteAlbums)
            }
            let current = await f.target
            let attemptedWrite = await f.library.writeTags(TagEdits(genre: "Other"), to: current.tracks)
            #expect(attemptedWrite.written.isEmpty)
            #expect(attemptedWrite.failures.count == current.tracks.count)
            await #expect(throws: AlbumDeletionError.self) { try await f.library.prepareAlbumDeletion(current) }
        }
        let request = try await f.library.prepareAlbumDeletion(f.target)
        #expect(await f.library.deleteAlbum(request).deleted.count == 2)
    }

    @Test func staleCatalogueAndChangedFilesKeepTheirRemainingTracks() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        let stale = try await f.library.prepareAlbumDeletion(f.target)
        f.installCatalogue()
        #expect(!f.library.canDeleteAlbum(using: stale))
        #expect(await f.library.deleteAlbum(stale).deleted.isEmpty)
        let request = try await f.library.prepareAlbumDeletion(f.target)
        await f.drive.setEntry(RemoteEntry(path: f.firstPath, name: "first.flac", isDirectory: false, size: 101, modified: f.modified))
        let report = await f.library.deleteAlbum(request)
        #expect(report.deleted.map(\.id) == [f.secondPath])
        #expect(report.failures.map(\.trackID) == [f.firstPath])
        #expect(report.remainingCount == 1)
        #expect(f.target.tracks.map(\.id) == [f.firstPath])
        #expect(await f.drive.attempts == [f.secondPath])
    }

    @Test func directoryReplacementCannotTurnAnAudioDeleteIntoAFolderDelete() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        let request = try await f.library.prepareAlbumDeletion(f.target)
        await f.drive.setEntry(RemoteEntry(path: f.firstPath, name: "first.flac", isDirectory: true, size: 100, modified: f.modified))
        let report = await f.library.deleteAlbum(request)
        #expect(report.failures.map(\.trackID) == [f.firstPath])
        #expect(await f.drive.attempts == [f.secondPath])
    }

    @Test func revocationDuringTheFinalInfoReadPreventsTheDestructiveCall() async throws {
        for kind in ["lock", "connection", "source"] {
            let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
            let request = try await f.library.prepareAlbumDeletion(f.target)
            await f.drive.setInfoHook { _ in
                await MainActor.run {
                    switch kind {
                    case "lock": f.profiles.lock()
                    case "connection": f.token = UUID()
                    default: f.installCatalogue(source: "another-NAS")
                    }
                }
            }
            let report = await f.library.deleteAlbum(request)
            #expect(report.deleted.isEmpty && report.wasCancelled)
            #expect(await f.drive.attempts.isEmpty)
            #expect(f.notifications.isEmpty)
        }
    }

    @Test func partialFailureOnlyRemovesConfirmedSongsAndTheirProfileReferences() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        f.profiles.updateLibrary(f.drive.id) {
            $0.favourites = [f.firstPath, f.secondPath, f.otherPath]
            $0.played = [f.firstPath, f.secondPath]
            $0.recentAlbums = ["Target Album", "Other Album"]
            $0.downloadedAlbums = ["Target Album", "Other Album"]
            $0.playlists = [LocalPlaylist(id: "mix", name: "Mix", trackIDs: [f.firstPath, f.secondPath, f.otherPath], created: .now)]
        }
        let request = try await f.library.prepareAlbumDeletion(f.target)
        await f.drive.setFailures([f.secondPath])
        let report = await f.library.deleteAlbum(request)
        #expect(report.deleted.map(\.id) == [f.firstPath])
        #expect(report.failures.map(\.trackID) == [f.secondPath])
        #expect(report.remainingCount == 1)
        #expect(f.target.tracks.map(\.id) == [f.secondPath])
        #expect(f.target.tracks.first?.index == 0)
        let state = f.profiles.libraryState(for: f.drive.id)
        #expect(state.favourites == [f.secondPath, f.otherPath])
        #expect(state.playlists.first?.trackIDs == [f.secondPath, f.otherPath])
        #expect(state.played == [f.secondPath])
        #expect(state.downloadedAlbums == ["Target Album", "Other Album"])
        #expect(f.savedCatalogues.count == 1)
    }

    @Test func deletingTheLastAlbumTrackRemovesOnlyThatAlbumsDownloadMembership() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        f.profiles.updateLibrary(f.drive.id) {
            $0.downloadedAlbums = ["Target Album", "Other Album"]
            $0.recentAlbums = ["Target Album", "Other Album"]
        }
        let report = await f.library.deleteAlbum(try await f.library.prepareAlbumDeletion(f.target))
        #expect(report.remainingCount == 0)
        #expect(f.profiles.libraryState(for: f.drive.id).downloadedAlbums == ["Other Album"])
        #expect(f.profiles.libraryState(for: f.drive.id).recentAlbums == ["Other Album"])
    }

    @Test func stopFinishesTheCurrentDeleteThenLeavesTheRestAndNextReviewUsable() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        let request = try await f.library.prepareAlbumDeletion(f.target)
        await f.drive.setDeleteHook { _ in await MainActor.run { f.library.cancelAlbumDeletion() } }
        let report = await f.library.deleteAlbum(request)
        #expect(report.deleted.map(\.id) == [f.firstPath])
        #expect(report.wasCancelled && report.remainingCount == 1)
        #expect(await f.drive.attempts == [f.firstPath])
        let retry = try await f.library.prepareAlbumDeletion(f.target)
        #expect(f.library.canDeleteAlbum(using: retry))
        let retried = await f.library.deleteAlbum(retry)
        #expect(retried.deleted.map(\.id) == [f.secondPath])
        #expect(retried.remainingCount == 0)
    }

    @Test func aSourceSwitchDuringDeletionNeverPatchesTheNewCatalogue() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        let request = try await f.library.prepareAlbumDeletion(f.target)
        await f.drive.setDeleteHook { _ in await MainActor.run { f.installCatalogue(source: "another-NAS"); f.token = UUID() } }
        let report = await f.library.deleteAlbum(request)
        #expect(report.deleted.map(\.id) == [f.firstPath])
        #expect(report.wasCancelled)
        #expect(f.library.catalogue.driveID == "another-NAS")
        #expect(f.library.catalogue.trackCount == 3)
        #expect(f.savedCatalogues.isEmpty)
        #expect(f.notifications.count == 1 && f.notifications[0].0 == f.drive.id)
        #expect(await f.drive.attempts == [f.firstPath])
    }

    @Test func failedLocalPersistenceDoesNotMisreportAConfirmedNASDeletion() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        f.persistenceSucceeds = false
        let report = await f.library.deleteAlbum(try await f.library.prepareAlbumDeletion(f.target))
        #expect(report.deleted.count == 2 && report.remainingCount == 0)
        #expect(report.persistenceError != nil)
        #expect(f.library.catalogue.trackCount == 1)
    }

    @Test func cancellingTheCallerCannotDiscardAnAcceptedDeleteAcknowledgement() async throws {
        let f = try AlbumDeletionFixture(); defer { f.cleanUp() }
        let request = try await f.library.prepareAlbumDeletion(f.target)
        await f.drive.holdNextDelete()
        let task = Task { await f.library.deleteAlbum(request) }
        for _ in 0..<200 {
            if await f.drive.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await f.drive.isWaiting)
        task.cancel()
        await f.drive.releaseDelete()
        let report = await task.value
        #expect(report.deleted.map(\.id) == [f.firstPath])
        #expect(report.wasCancelled && report.remainingCount == 1)
        #expect(f.target.tracks.map(\.id) == [f.secondPath])
        #expect(f.savedCatalogues.count == 1)
    }
}

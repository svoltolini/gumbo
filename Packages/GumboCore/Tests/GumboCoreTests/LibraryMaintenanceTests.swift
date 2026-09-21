import Foundation
import Testing
@testable import GumboCore

@Suite struct GenreLookupTests {
    private func response(_ genres: [String], album: String = "A Radiant Sign", artist: String = "Nils Hoffmann", url: String = "https://music.apple.com/gb/album/example/123") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["results": genres.map {
            ["collectionName": album, "artistName": artist, "primaryGenreName": $0, "collectionViewUrl": url]
        }])
    }

    @Test func matchesAlbumAndCompleteArtistCreditWithConservativeNormalization() throws {
        let match = try GenreLookup.match(data: response(["Dance"]), album: "A RADIANT SIGN", artist: "Nils Hoffmann")
        #expect(match?.genre == "Dance")
        #expect(try GenreLookup.match(data: response(["Dance"]), album: "A Radiant Sign (Remixed)", artist: "Nils Hoffmann") == nil)
        #expect(try GenreLookup.match(data: response(["Dance"]), album: "A Radiant Sign", artist: "Someone Else") == nil)
        #expect(try GenreLookup.match(data: response(["Dance"], artist: "Nils Hoffmann & Other Artist"), album: "A Radiant Sign", artist: "Nils Hoffmann") == nil)
        #expect(try GenreLookup.match(data: response(["Rock"], album: "Álbum—One", artist: "Música"), album: "Album One", artist: "Musica")?.genre == "Rock")
    }

    @Test func conflictingOrUninformativeSuggestionsNeverBecomeAnAutomaticChoice() throws {
        #expect(try GenreLookup.match(data: response(["Dance", "Electronic"]), album: "A Radiant Sign", artist: "Nils Hoffmann") == nil)
        #expect(try GenreLookup.match(data: response(["Music"]), album: "A Radiant Sign", artist: "Nils Hoffmann") == nil)
        #expect(try GenreLookup.match(data: response(["Dance"], url: "https://other.example/album"), album: "A Radiant Sign", artist: "Nils Hoffmann") == nil)
        #expect(try GenreLookup.match(data: Data("{\"results\":[]}".utf8), album: "Missing", artist: "Nobody") == nil)
    }

    @Test func unknownTagsAndHashFileNamesAreNotGoodSearchInputs() {
        for value in [nil, "", " No Genre ", "unknown genre", "UNKNOWN"] as [String?] { #expect(GenreLookup.isMissing(value)) }
        for value in ["Other", "World", "Alternative", "Unclassified"] { #expect(!GenreLookup.isMissing(value)) }
        #expect(!GenreLookup.canSearch(album: "0123456789abcdef0123456789abcdef", artist: "Someone"))
        #expect(!GenreLookup.canSearch(album: "Album", artist: "Unknown Artist"))
    }
}

private actor InspectionDrive: WritableRemoteDrive {
    nonisolated let capabilities: RemoteCapabilities = [.read, .ranges, .upload, .rename, .delete, .replace]
    nonisolated let id = "inspection-fixture"
    nonisolated let displayName = "Inspection fixture"
    var bytes: Data
    var modified: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    var version: String?
    var directory = false
    var error: (any Error)?
    var shortRead = false
    var changeOnRead = false
    var deleted: [String] = []
    var onRead: (@Sendable () async -> Void)?
    var deleteWaiter: CheckedContinuation<Void, Never>?
    var holdsDeletion = false
    var deletionFailure: RemoteWriteError?
    var deletionAttempts = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func setModified(_ value: Date?) { modified = value }
    func setVersion(_ value: String) { version = value }
    func setDirectory() { directory = true }
    func setError(_ value: any Error) { error = value }
    func setShortRead() { shortRead = true }
    func setChangeOnRead() { changeOnRead = true }
    func setBytes(_ value: Data) { bytes = value }
    func setOnRead(_ hook: @escaping @Sendable () async -> Void) { onRead = hook }
    func holdDeletion() { holdsDeletion = true }
    func failDeletion(_ failure: RemoteWriteError) { deletionFailure = failure }
    func releaseDeletion() { holdsDeletion = false; deleteWaiter?.resume(); deleteWaiter = nil }
    var isDeleting: Bool { deleteWaiter != nil }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func info(_ path: String) async throws -> RemoteEntry {
        if let error { throw error }
        return RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: directory, size: Int64(bytes.count), modified: modified, version: version)
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        if let error { throw error }
        if changeOnRead { modified = modified?.addingTimeInterval(1) }
        if let onRead { await onRead() }
        let part = bytes.subdata(in: min(Int(range.lowerBound), bytes.count)..<min(Int(range.upperBound), bytes.count))
        return shortRead ? Data(part.dropLast()) : part
    }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { bytes }
    nonisolated func streamURL(for path: String) -> URL? { nil }
    func upload(_ file: URL, toFolder folder: String, name: String, modified: Date?) async throws { throw RemoteWriteError.readOnly }
    func rename(_ path: String, to name: String) async throws { throw RemoteWriteError.readOnly }
    func delete(_ path: String) async throws {
        deletionAttempts += 1
        if let error { throw error }
        if holdsDeletion { await withCheckedContinuation { deleteWaiter = $0 } }
        if let deletionFailure { throw deletionFailure }
        try Task.checkCancellation()
        deleted.append(path)
    }
}

private nonisolated func word(_ value: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}
private nonisolated func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { word(UInt32(payload.count + 8)) + Array(type.utf8) + payload }
private nonisolated let brokenAudio = Data(box("ftyp", Array("M4A ".utf8) + word(0)) + box("mdat", [UInt8](repeating: 0, count: 64)))
private nonisolated let validAudio: Data = {
    var header = [UInt8](repeating: 0, count: 100)
    header.replaceSubrange(12..<20, with: word(1000) + word(90_000))
    var sample = [UInt8](repeating: 0, count: 28)
    sample.replaceSubrange(24..<28, with: word(44_100 << 16))
    let stsd = box("stsd", word(0) + word(1) + box("mp4a", sample))
    let handler = box("hdlr", word(0) + word(0) + Array("soun".utf8) + [UInt8](repeating: 0, count: 13))
    let track = box("trak", box("mdia", handler + box("minf", box("stbl", stsd))))
    return brokenAudio + Data(box("moov", box("mvhd", header) + track))
}()
private nonisolated func inspectionTrack(_ path: String = "/music/0123456789abcdef0123456789abcdef.m4a") -> Track {
    let entry = RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: false, size: nil, modified: nil)
    return Catalogue.build(folders: [ScannedFolder(path: "/music", audio: [entry], cover: nil)], rootPath: "/music",
                           serverName: "Fixture", driveID: "inspection-fixture", existing: nil).albums[0].tracks[0]
}

@Suite struct MusicFileInspectionTests {
    @Test func fabricatedDamageWithoutAProviderReviewCannotAuthorizeDeletion() async throws {
        let drive = InspectionDrive(Data())
        let finding = MusicFileInspection(track: inspectionTrack(), sourceID: drive.id, condition: .damaged,
            explanation: "Unverified input", size: 0, modified: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(!finding.canDelete)
        await #expect(throws: RemoteWriteError.changed) {
            try await MusicFileInspector.deleteReviewed(finding, drive: drive, authorized: { true })
        }
        #expect(await drive.deletionAttempts == 0)
    }

    @MainActor @Test func lostReplyStopsDamagedFileBatchAndSurvivesCancellation() async throws {
        for cancel in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appending(path: "GumboDamageBatch-" + UUID().uuidString)
            let suite = "GumboDamageBatch." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
            let profiles = ProfileStore(directory: directory, defaults: defaults)
            #expect(profiles.activate(try #require(profiles.owner)))
            let drive = InspectionDrive(Data())
            let entries = ["one.m4a", "two.m4a"].map {
                RemoteEntry(path: "/music/" + $0, name: $0, isDirectory: false, size: 0,
                            modified: Date(timeIntervalSince1970: 1_700_000_000))
            }
            let library = LibraryStore()
            library.profiles = profiles
            library.replace(with: Catalogue.build(folders: [ScannedFolder(path: "/music", audio: entries, cover: nil)],
                rootPath: "/music", serverName: "Fixture", driveID: drive.id, existing: nil), drive: drive)
            let token = UUID()
            library.fileDeletionConnectionTokenProvider = { token }
            var findings: [MusicFileInspection] = []
            for track in library.tracks { findings.append(await MusicFileInspector.inspect(track, drive: drive)) }
            await drive.failDeletion(.deletionUnconfirmed)
            await drive.holdDeletion()
            let task = Task { await library.deleteReviewedFiles(findings) }
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await drive.isDeleting), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await drive.isDeleting)
            if cancel { task.cancel() }
            await drive.releaseDeletion()
            let report = await task.value
            #expect(report.deleted.isEmpty && report.failures.count == 1)
            #expect(report.failures.first?.message.contains("reply was lost") == true)
            #expect(report.wasCancelled == cancel)
            #expect(await drive.deletionAttempts == 1)
            #expect(library.catalogue.trackCount == 2)
        }
    }
    @Test func missingIndexIsDamagedButHashedNameWithReadableAudioIsKept() async {
        let broken = await MusicFileInspector.inspect(inspectionTrack(), drive: InspectionDrive(brokenAudio))
        #expect(broken.condition == .damaged && broken.canDelete)
        let valid = await MusicFileInspector.inspect(inspectionTrack(), drive: InspectionDrive(validAudio))
        #expect(valid.condition == .readable && !valid.canDelete)
    }

    @Test func unfamiliarFormatsAreNeverJudgedByTheirExtensionOrName() async {
        let unrecognised = await MusicFileInspector.inspect(inspectionTrack(), drive: InspectionDrive(Data([0xFF, 0xF1, 0, 0])))
        #expect(unrecognised.condition == .unsupported && !unrecognised.canDelete)
        let other = await MusicFileInspector.inspect(inspectionTrack("/music/hash.flac"), drive: InspectionDrive(Data([1, 2, 3])))
        #expect(other.condition == .unsupported && !other.canDelete)
    }

    @Test func unknownOrRecentModificationTimeAndDirectoriesAreProtected() async {
        let drive = InspectionDrive(Data())
        await drive.setModified(.now)
        #expect(await MusicFileInspector.inspect(inspectionTrack(), drive: drive).condition == .changing)
        await drive.setModified(nil)
        #expect(await MusicFileInspector.inspect(inspectionTrack(), drive: drive).canDelete == false)
        await drive.setModified(Date(timeIntervalSince1970: 1_700_000_000))
        await drive.setDirectory()
        #expect(await MusicFileInspector.inspect(inspectionTrack(), drive: drive).canDelete == false)
    }

    @Test func shortResponsesAndDeniedOrDisconnectedRequestsAreNotCorruption() async {
        let short = InspectionDrive(brokenAudio)
        await short.setShortRead()
        #expect(await MusicFileInspector.inspect(inspectionTrack(), drive: short).condition == .unavailable)
        for error: any Error in [URLError(.notConnectedToInternet), RemoteWriteError.readOnly, RemoteWriteError.missing] {
            let drive = InspectionDrive(brokenAudio)
            await drive.setError(error)
            #expect(await MusicFileInspector.inspect(inspectionTrack(), drive: drive).canDelete == false)
        }
    }

    @Test func changingFilesAreKeptAndOldEmptyFilesRequireExplicitReviewedDeletion() async throws {
        let changing = InspectionDrive(brokenAudio)
        await changing.setChangeOnRead()
        #expect(await MusicFileInspector.inspect(inspectionTrack(), drive: changing).condition == .changing)
        let empty = InspectionDrive(Data())
        let finding = await MusicFileInspector.inspect(inspectionTrack(), drive: empty)
        #expect(finding.canDelete)
        #expect(await empty.deleted.isEmpty)
        try await MusicFileInspector.deleteReviewed(finding, drive: empty, authorized: { true })
        #expect(await empty.deleted == [inspectionTrack().path!])
    }

    @Test func repairedOrChangedFilesCannotBeDeletedUsingAnOldReview() async throws {
        let drive = InspectionDrive(brokenAudio)
        let finding = await MusicFileInspector.inspect(inspectionTrack(), drive: drive)
        await drive.setBytes(validAudio)
        await #expect(throws: RemoteWriteError.changed) {
            try await MusicFileInspector.deleteReviewed(finding, drive: drive, authorized: { true })
        }
        await drive.setBytes(brokenAudio)
        await drive.setModified(Date(timeIntervalSince1970: 1_700_000_100))
        await #expect(throws: RemoteWriteError.changed) {
            try await MusicFileInspector.deleteReviewed(finding, drive: drive, authorized: { true })
        }
        #expect(await drive.deleted.isEmpty)
    }

    @Test func aChangedStrongVersionInvalidatesDamagedFileReviewEvenWhenSizeAndTimeMatch() async throws {
        let drive = InspectionDrive(brokenAudio)
        await drive.setVersion("reviewed")
        let finding = await MusicFileInspector.inspect(inspectionTrack(), drive: drive)
        #expect(finding.version == "reviewed")
        await drive.setVersion("replacement")
        await #expect(throws: RemoteWriteError.changed) {
            try await MusicFileInspector.deleteReviewed(finding, drive: drive, authorized: { true })
        }
        #expect(await drive.deleted.isEmpty)
    }

    @MainActor @Test func aProfileLockDuringRecheckingRevokesDeletion() async throws {
        let drive = InspectionDrive(brokenAudio)
        let finding = await MusicFileInspector.inspect(inspectionTrack(), drive: drive)
        let allowed = MaintenanceAuthorization()
        await drive.setOnRead { await allowed.revoke() }
        await #expect(throws: MetadataWriteError.notAuthorized) {
            try await MusicFileInspector.deleteReviewed(finding, drive: drive, authorized: { allowed.value })
        }
        #expect(await drive.deleted.isEmpty)
    }

    @Test func stoppingAfterSubmissionStillAccountsForConfirmedDamagedFileDeletion() async throws {
        let drive = InspectionDrive(Data())
        let finding = await MusicFileInspector.inspect(inspectionTrack(), drive: drive)
        await drive.holdDeletion()
        let task = Task { try await MusicFileInspector.deleteReviewed(finding, drive: drive, authorized: { true }) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await drive.isDeleting), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await drive.isDeleting)
        task.cancel()
        await drive.releaseDeletion()
        try await task.value
        #expect(await drive.deleted == [inspectionTrack().path!])
    }

    @MainActor @Test func membersAndLockedOwnersCannotRunSharedFileMaintenance() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "maintenance-profiles-\(UUID())")
        let suite = "maintenance-profiles-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileStore(directory: directory, defaults: defaults)
        let owner = try #require(profiles.owner)
        #expect(profiles.activate(owner))
        let member = try #require(profiles.create(name: "Member", avatar: .random(), pin: nil))
        let drive = InspectionDrive(brokenAudio)
        let track = inspectionTrack()
        let entry = try await drive.info(track.path!)
        let library = LibraryStore()
        library.replace(with: Catalogue.build(folders: [ScannedFolder(path: "/music", audio: [entry], cover: nil)], rootPath: "/music", serverName: "Fixture", driveID: drive.id, existing: nil), drive: drive)
        library.profiles = profiles
        #expect(library.canMaintainFiles)
        let finding = await MusicFileInspector.inspect(track, drive: drive)
        #expect(profiles.activate(member))
        #expect(!library.canMaintainFiles)
        #expect(await library.deleteReviewedFiles([finding]).deleted.isEmpty)
        #expect(await library.fillMissingGenre("Dance", trackIDs: [track.id]).written.isEmpty)
        #expect(await drive.deleted.isEmpty)
        #expect(profiles.activate(owner))
        profiles.lock()
        #expect(!library.canMaintainFiles)
        #expect(await library.deleteReviewedFiles([finding]).deleted.isEmpty)
        #expect(await drive.deleted.isEmpty)
    }

    @Test func invalidLengthsAndHugeUnsignedLengthsDoNotOverflow() async {
        let ftyp = box("ftyp", Array("M4A ".utf8) + word(0))
        for tail in [word(200) + Array("mdat".utf8), word(1) + Array("mdat".utf8) + [UInt8](repeating: 255, count: 8), [UInt8](repeating: 0, count: 3)] {
            let result = await MusicFileInspector.inspect(inspectionTrack(), drive: InspectionDrive(Data(ftyp + tail)))
            #expect(result.condition == .damaged)
        }
    }

    @MainActor @Test func successfulDeletionRemovesOnlyTheReviewedSongFromTheCatalogue() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GumboMaintenanceOwner-" + UUID().uuidString)
        let suite = "GumboMaintenanceOwner." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileStore(directory: directory, defaults: defaults)
        #expect(profiles.activate(try #require(profiles.owner)))
        let drive = InspectionDrive(brokenAudio)
        let entries = ["one.m4a", "two.m4a"].map { RemoteEntry(path: "/music/" + $0, name: $0, isDirectory: false, size: Int64(brokenAudio.count), modified: Date(timeIntervalSince1970: 1_700_000_000)) }
        let catalogue = Catalogue.build(folders: [ScannedFolder(path: "/music", audio: entries, cover: nil)], rootPath: "/music", serverName: "Fixture", driveID: drive.id, existing: nil)
        let library = LibraryStore()
        library.replace(with: catalogue, drive: drive)
        library.persistDeletedAlbumCatalogue = { _ in true }
        library.profiles = profiles
        let connectionToken = UUID()
        library.fileDeletionConnectionTokenProvider = { connectionToken }
        let track = try #require(library.tracks.first)
        profiles.updateLibrary(drive.id) { state in state.favourites = [track.id]; state.played = [track.id] }
        var notifications: [(String, Set<String>)] = []
        library.onServerTracksDeleted = { source, ids in notifications.append((source, ids)) }
        let finding = await MusicFileInspector.inspect(track, drive: drive)
        let report = await library.deleteReviewedFiles([finding])
        #expect(report.deleted.map(\.id) == [track.id])
        #expect(report.failures.isEmpty)
        #expect(library.catalogue.trackCount == 1)
        #expect(library.catalogue.albums[0].tracks[0].index == 0)
        #expect(notifications.count == 1 && notifications.first?.0 == drive.id && notifications.first?.1 == [track.id])
        #expect(profiles.libraryState(for: drive.id).favourites.isEmpty)
        #expect(profiles.libraryState(for: drive.id).played.isEmpty)
    }
}

@MainActor private final class MaintenanceAuthorization {
    var value = true
    func revoke() { value = false }
}

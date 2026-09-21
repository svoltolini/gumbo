import Foundation
import Testing
@testable import GumboCore

/// A music folder in memory with the write half of a drive, plus knobs for refusals and a hook
/// that fires while a file is being uploaded.
private actor WriterFixtureDrive: WritableRemoteDrive {
    nonisolated let capabilities: RemoteCapabilities = [.read, .ranges, .upload, .rename, .delete, .replace]
    let id = "writer-fixture"
    let displayName = "Writer fixture"
    var files: [String: Data]
    var calls: [String] = []
    var uploadError: (any Error)?
    var onInfo: (@Sendable () async -> Void)?
    var onUpload: (@Sendable () async -> Void)?

    init(files: [String: Data]) {
        self.files = files
    }

    func setFile(_ path: String, _ data: Data) { files[path] = data }
    func setUploadError(_ error: (any Error)?) { uploadError = error }
    func setOnInfo(_ hook: (@Sendable () async -> Void)?) { onInfo = hook }
    func setOnUpload(_ hook: (@Sendable () async -> Void)?) { onUpload = hook }

    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { throw RemoteWriteError.missing }
    nonisolated func streamURL(for path: String) -> URL? { nil }

    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        guard let data = files[path] else { throw SynologyError.api(code: 408, api: "SYNO.FileStation.Download") }
        return data.subdata(in: min(data.count, Int(range.lowerBound))..<min(data.count, Int(range.upperBound)))
    }

    func info(_ path: String) async throws -> RemoteEntry {
        if let onInfo { await onInfo() }
        guard let data = files[path] else { throw SynologyError.api(code: 408, api: "SYNO.FileStation.List") }
        return RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: false, size: Int64(data.count), modified: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func upload(_ file: URL, toFolder folder: String, name: String, modified: Date?) async throws {
        calls.append("upload \(name) mtime=\(modified?.timeIntervalSince1970 ?? 0)")
        if let uploadError { throw uploadError }
        files[folder + "/" + name] = try Data(contentsOf: file)
        if let onUpload { await onUpload() }
    }

    func rename(_ path: String, to name: String) async throws {
        let target = (path as NSString).deletingLastPathComponent + "/" + name
        guard let data = files[path], files[target] == nil else { throw SynologyError.api(code: 1200, api: "SYNO.FileStation.Rename") }
        files[path] = nil
        files[target] = data
    }

    func delete(_ path: String) async throws {
        guard files[path] != nil else { throw SynologyError.api(code: 408, api: "SYNO.FileStation.Delete") }
        files[path] = nil
    }
}

private nonisolated let folder = "/music/Halden Vey/Nocturne Drift"
private nonisolated let mp3Path = folder + "/01 Morning.mp3"
private nonisolated let flacPath = folder + "/02 Second Light.flac"
private nonisolated let wavPath = folder + "/03 Tide.wav"

private nonisolated func be32(_ value: Int) -> [UInt8] {
    [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
}

private nonisolated func le32(_ value: Int) -> [UInt8] {
    [UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8((value >> 24) & 255)]
}

/// A v2.3 tag with a title and genre in front of one MPEG frame.
private nonisolated let mp3Bytes: [UInt8] = {
    func text(_ id: String, _ value: String) -> [UInt8] {
        let payload: [UInt8] = [0] + Array(value.utf8)
        return Array(id.utf8) + be32(payload.count) + [0, 0] + payload
    }
    let frames = text("TIT2", "Morning") + text("TCON", "Rock") + text("TALB", "Nocturne Drift")
    let size = frames.count + 32
    let header: [UInt8] = Array("ID3".utf8) + [3, 0, 0] + [UInt8((size >> 21) & 127), UInt8((size >> 14) & 127), UInt8((size >> 7) & 127), UInt8(size & 127)]
    let audio: [UInt8] = [0xFF, 0xFB, 0x90, 0x00] + (0..<413).map { (index: Int) -> UInt8 in UInt8(truncatingIfNeeded: index &* 7 &+ 3) }
    return header + frames + [UInt8](repeating: 0, count: 32) + audio
}()

/// Stream info and comments in front of a fake frame.
private nonisolated let flacBytes: [UInt8] = {
    var info = [UInt8](repeating: 0, count: 34)
    info[10] = 0x0A; info[11] = 0xC4; info[12] = 0x42; info[13] = 0xF0; info[14] = 0x06; info[15] = 0xBA; info[16] = 0xA8
    let comments = ["TITLE=Second Light", "GENRE=Rock", "ALBUM=Nocturne Drift"]
    let vendor = Array("Gumbo".utf8)
    var block = le32(vendor.count) + vendor + le32(comments.count)
    for comment in comments { block += le32(comment.utf8.count) + Array(comment.utf8) }
    func header(_ type: UInt8, _ length: Int, last: Bool) -> [UInt8] {
        [type | (last ? 0x80 : 0), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)]
    }
    let padding = [UInt8](repeating: 0, count: 64)
    var file: [UInt8] = Array("fLaC".utf8)
    file += header(0, info.count, last: false) + info
    file += header(4, block.count, last: false) + block
    file += header(1, padding.count, last: true) + padding
    file += [0xFF, 0xF8, 0x69, 0x08]
    file += [UInt8](repeating: 0x5A, count: 200)
    return file
}()

private nonisolated func track(_ path: String?, title: String) -> Track {
    Track(
        id: path ?? title, albumID: "album", title: title, index: 0, number: 1, disc: 1, duration: 100, codec: "mp3",
        sampleRate: nil, bitDepth: nil, bitrate: nil, fileSize: nil, path: path, format: "MP3", artist: nil,
        albumTitleTag: "Nocturne Drift", albumArtistTag: nil, yearTag: nil, genreTag: "Rock", isEnriched: true
    )
}

private nonisolated func fixtureDrive() -> WriterFixtureDrive {
    WriterFixtureDrive(files: [mp3Path: Data(mp3Bytes), flacPath: Data(flacBytes), wavPath: Data([UInt8](repeating: 0, count: 300))])
}

private nonisolated func readTags(_ drive: WriterFixtureDrive, _ path: String) async throws -> WrittenTags? {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: (path as NSString).lastPathComponent)
    guard let data = await drive.files[path] else { return nil }
    try data.write(to: url)
    return try await TagWriter.readBack(fileName: (path as NSString).lastPathComponent, at: url)
}

@Suite @MainActor struct MetadataWriterTests {
    @Test func genreIsWrittenIntoEachSupportedFileAndReportedPerSong() async throws {
        let drive = fixtureDrive()
        let writer = MetadataWriter()
        let tracks = [track(mp3Path, title: "Morning"), track(flacPath, title: "Second Light"), track(wavPath, title: "Tide"), track(nil, title: "Ghost")]
        let report = await writer.write(TagEdits(genre: "Ambient"), to: tracks, drive: drive)
        #expect(report.written.map(\.id) == [mp3Path, flacPath])
        #expect(report.failures.map(\.trackID) == [wavPath, "Ghost"])
        #expect(report.failures[0].message == TagWriteError.unsupportedFormat("wav").localizedDescription)
        #expect(report.failures[1].message == MetadataWriteError.noFile.localizedDescription)
        #expect(report.reasons.count == 2)
        #expect(!report.isComplete)
        #expect(!report.wasCancelled)
        for path in [mp3Path, flacPath] {
            let tags = try #require(try await readTags(drive, path))
            #expect(tags.genre == "Ambient")
            #expect(tags.album == "Nocturne Drift")
        }
        let mp3Tags = try await readTags(drive, mp3Path)
        #expect(mp3Tags?.title == "Morning")
        let written = report.written[0]
        let files = await drive.files
        #expect(written.genreTag == "Ambient")
        #expect(written.albumTitleTag == "Nocturne Drift")
        #expect(written.fileSize == Int64(files[mp3Path]?.count ?? 0))
        #expect(written.sourceModifiedAt == 1_700_000_001)
        let calls = await drive.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.hasSuffix("mtime=1700000001.0") && $0.contains(".gumbo-upload") })
        #expect(files.keys.allSatisfy { !$0.contains(".gumbo-") })
        #expect(files.count == 3)
        #expect(!writer.isWriting)
        #expect(writer.completed == 4)
        #expect(writer.total == 4)
    }

    @Test func filesAlreadyCarryingTheValueAreNotTransferred() async throws {
        let drive = fixtureDrive()
        let before = await drive.files
        let report = await MetadataWriter().write(TagEdits(genre: "Rock"), to: [track(mp3Path, title: "Morning"), track(flacPath, title: "Second Light")], drive: drive)
        #expect(report.unchanged.count == 2)
        #expect(report.written.isEmpty)
        #expect(report.isComplete)
        let calls = await drive.calls
        let after = await drive.files
        #expect(calls.isEmpty)
        #expect(after == before)
    }

    @Test func readOnlyAccountStopsAfterTheFirstRefusal() async throws {
        let drive = fixtureDrive()
        await drive.setUploadError(SynologyError.api(code: 407, api: "SYNO.FileStation.Upload"))
        let before = await drive.files
        let report = await MetadataWriter().write(TagEdits(genre: "Ambient"), to: [track(mp3Path, title: "Morning"), track(flacPath, title: "Second Light")], drive: drive)
        #expect(report.written.isEmpty)
        #expect(report.failures.count == 2)
        #expect(report.reasons == [RemoteWriteError.readOnly.localizedDescription])
        let calls = await drive.calls
        let after = await drive.files
        #expect(calls.count == 1)
        #expect(after == before)
    }

    @Test func stoppingDuringUploadPreservesTheOriginalAndLeavesTheRestUntouched() async throws {
        let drive = fixtureDrive()
        let writer = MetadataWriter()
        await drive.setOnUpload { await writer.cancel() }
        let before = await drive.files
        let report = await writer.write(TagEdits(genre: "Ambient"), to: [track(mp3Path, title: "Morning"), track(flacPath, title: "Second Light")], drive: drive)
        #expect(report.wasCancelled)
        #expect(report.written.isEmpty)
        #expect(report.failures.isEmpty)
        let mp3Tags = try await readTags(drive, mp3Path)
        let after = await drive.files
        #expect(mp3Tags?.genre == "Rock")
        #expect(after == before)
        #expect(!writer.isWriting)
    }

    @Test func albumRenameKeepsEveryOtherTag() async throws {
        let drive = fixtureDrive()
        let report = await MetadataWriter().write(TagEdits(album: "Second Light Sessions"), to: [track(mp3Path, title: "Morning"), track(flacPath, title: "Second Light")], drive: drive)
        #expect(report.isComplete)
        #expect(report.written.allSatisfy { $0.albumTitleTag == "Second Light Sessions" && $0.genreTag == "Rock" })
        let mp3 = try #require(try await readTags(drive, mp3Path))
        #expect(mp3.album == "Second Light Sessions")
        #expect(mp3.title == "Morning")
        #expect(mp3.genre == "Rock")
        let flac = try #require(try await readTags(drive, flacPath))
        #expect(flac.album == "Second Light Sessions")
        #expect(flac.title == "Second Light")
        #expect(flac.genre == "Rock")
    }

    /// A library over the fixture folder, every song read with "Rock" and the folder's album title.
    private func library(over drive: WriterFixtureDrive) async -> LibraryStore {
        let files = await drive.files
        let entries = [mp3Path, flacPath, wavPath].map { path in
            RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: false, size: Int64(files[path]?.count ?? 0), modified: Date(timeIntervalSince1970: 1_700_000_000))
        }
        var catalogue = Catalogue.build(folders: [ScannedFolder(path: folder, audio: entries, cover: nil)], rootPath: "/music", serverName: "Fixture NAS", driveID: drive.id, existing: nil)
        for album in catalogue.albums.indices {
            for index in catalogue.albums[album].tracks.indices {
                catalogue.albums[album].tracks[index].isEnriched = true
                catalogue.albums[album].tracks[index].tagVersion = Track.currentTagVersion
                catalogue.albums[album].tracks[index].genreTag = "Rock"
                catalogue.albums[album].tracks[index].albumTitleTag = "Nocturne Drift"
            }
            catalogue.albums[album].refreshFromTags()
        }
        let library = LibraryStore()
        library.replace(with: catalogue, drive: drive)
        // Aliases persist per source in UserDefaults; a previous run must not leak into this one.
        library.resetGenreNames()
        return library
    }

    @Test func libraryWritesAGenreAndFallsBackToAnAliasForFilesItCouldNotChange() async throws {
        let covers = FileManager.default.temporaryDirectory.appending(path: "gumbo-writer-covers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: covers) }
        try await CoverStore.$directoryOverride.withValue(covers) {
            let drive = fixtureDrive()
            let library = await self.library(over: drive)
            #expect(library.canWriteTags)
            #expect(library.tracks(shownUnderGenre: "Rock").count == 3)
            #expect(library.tracksCarryingAnotherTag(underGenre: "Rock").isEmpty)
            let report = await library.writeGenre("Rock", to: "Ambient")
            #expect(report.written.map(\.id) == [mp3Path, flacPath])
            #expect(report.failures.map(\.trackID) == [wavPath])
            let tracks = Dictionary(uniqueKeysWithValues: library.catalogue.albums.flatMap(\.tracks).map { ($0.id, $0) })
            #expect(tracks[mp3Path]?.genreTag == "Ambient")
            #expect(tracks[flacPath]?.genreTag == "Ambient")
            #expect(tracks[wavPath]?.genreTag == "Rock")
            #expect(tracks[mp3Path]?.sourceModifiedAt == 1_700_000_001)
            #expect(library.genreRenames.map { "\($0.tag)→\($0.name)" } == ["Rock→Ambient"])
            #expect(library.tracks(shownUnderGenre: "Ambient").count == 3)
            #expect(library.tracks(shownUnderGenre: "Rock").isEmpty)
            #expect(library.tracksCarryingAnotherTag(underGenre: "Ambient").map(\.id) == [wavPath])
            let mp3 = try #require(try await readTags(drive, mp3Path))
            #expect(mp3.genre == "Ambient")
            #expect(mp3.title == "Morning")
            // Writing the shown name again only touches the file that still carries the old tag, and fails the same way.
            let again = await library.writeGenre("Ambient", to: "Ambient")
            #expect(again.written.isEmpty)
            #expect(again.unchanged.count == 2)
            #expect(again.failures.map(\.trackID) == [wavPath])
            let calls = await drive.calls
            #expect(calls.count == 2)
            library.resetGenreNames()
        }
    }

    @Test func libraryRenamesAnAlbumAndFollowsItToItsNewIdentity() async throws {
        let covers = FileManager.default.temporaryDirectory.appending(path: "gumbo-writer-covers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: covers) }
        try await CoverStore.$directoryOverride.withValue(covers) {
            let drive = fixtureDrive()
            let library = await self.library(over: drive)
            var renames: [(String, String)] = []
            library.onAlbumRenamed = { renames.append(($0, $1)) }
            let album = try #require(library.catalogue.albums.first)
            #expect(album.title == "Nocturne Drift")
            let outcome = await library.renameAlbum(album, to: "Second Light Sessions")
            #expect(outcome.report.written.count == 2)
            #expect(outcome.report.failures.map(\.trackID) == [wavPath])
            #expect(outcome.albumID == Album.makeID(title: "Second Light Sessions", artist: album.artist))
            #expect(renames.map(\.0) == [album.id])
            #expect(renames.map(\.1) == [outcome.albumID])
            let renamed = try #require(library.catalogue.albums.first { $0.id == outcome.albumID })
            #expect(renamed.title == "Second Light Sessions")
            #expect(renamed.genre == "Rock")
            #expect(renamed.tracks.map(\.id) == [mp3Path, flacPath])
            #expect(renamed.tracks.allSatisfy { $0.albumTitleTag == "Second Light Sessions" && $0.genreTag == "Rock" })
            // The song that could not be written keeps the old title in its file and stays under it.
            let remaining = try #require(library.catalogue.albums.first { $0.id == album.id })
            #expect(remaining.tracks.map(\.id) == [wavPath])
            let flac = try #require(try await readTags(drive, flacPath))
            #expect(flac.album == "Second Light Sessions")
            #expect(flac.albumArtist == album.artist)
            #expect(flac.title == "Second Light")
            #expect(renamed.tracks.allSatisfy { $0.albumArtistTag == album.artist })
        }
    }

    @Test func verificationRefusesAnyDriftInUneditedFields() {
        let before = WrittenTags(title: "Morning", artist: "Halden Vey", album: "Nocturne Drift", genre: "Rock", trackNumber: 1)
        var after = before
        after.genre = "Ambient"
        #expect(throws: Never.self) { try MetadataWriter.verify(before: before, after: after, edits: TagEdits(genre: "Ambient")) }
        after.albumArtist = "Unexpected artist"
        #expect(throws: MetadataWriteError.verificationFailed) { try MetadataWriter.verify(before: before, after: after, edits: TagEdits(genre: "Ambient")) }
        after.albumArtist = before.albumArtist
        after.title = "Evening"
        #expect(throws: MetadataWriteError.verificationFailed) { try MetadataWriter.verify(before: before, after: after, edits: TagEdits(genre: "Ambient")) }
        after = before
        #expect(throws: MetadataWriteError.verificationFailed) { try MetadataWriter.verify(before: before, after: after, edits: TagEdits(genre: "Ambient")) }
        after.album = "Live (Disc 2)"
        var renamed = after
        renamed.album = "Concert (Disc 2)"
        #expect(throws: Never.self) { try MetadataWriter.verify(before: after, after: renamed, edits: TagEdits(album: "Concert")) }
    }
}

extension MetadataWriterTests {
    @Test func lockingDuringUploadPreventsTheSwapAndDoesNotStartAnotherSong() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "writer-late-lock-\(UUID())")
        let suite = "writer-late-lock-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileStore(directory: directory, defaults: defaults)
        let drive = fixtureDrive()
        let library = await self.library(over: drive)
        library.profiles = profiles
        profiles.onDeactivate = { library.metadataWriter.cancel() }
        #expect(profiles.activate(try #require(profiles.owner)))
        let original = await drive.files
        await drive.setOnUpload { await profiles.lock() }
        let report = await library.writeTags(TagEdits(genre: "Ambient"), to: [track(mp3Path, title: "Morning"), track(flacPath, title: "Second Light")])
        #expect(profiles.isLocked && report.wasCancelled)
        #expect(report.written.isEmpty)
        #expect(await drive.calls.count == 1)
        #expect(try await readTags(drive, mp3Path)?.genre == "Rock")
        #expect(await drive.files[flacPath] == original[flacPath])
        #expect(await drive.files.keys.sorted() == original.keys.sorted())
    }

    @Test func lockedProfileAndLockDuringReadCannotReplaceNASFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "writer-auth-\(UUID())")
        let suite = "writer-auth-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileStore(directory: directory, defaults: defaults)
        let drive = fixtureDrive()
        let library = await self.library(over: drive)
        library.profiles = profiles
        let original = await drive.files
        let locked = await library.writeTags(TagEdits(album: "Rejected"), to: library.tracks)
        #expect(!locked.isComplete && locked.written.isEmpty)
        #expect(await drive.calls.isEmpty)
        #expect(profiles.activate(try #require(profiles.owner)))
        var invalidatedScan = false
        library.onMetadataWriteWillBegin = { invalidatedScan = library.metadataMutationRevision > 0 }
        await drive.setOnInfo { await profiles.lock() }
        let suspended = await library.writeTags(TagEdits(album: "Also rejected"), to: library.tracks)
        #expect(invalidatedScan)
        #expect(!suspended.isComplete && suspended.written.isEmpty)
        #expect(await drive.calls.isEmpty)
        #expect(await drive.files == original)
        await drive.setOnInfo(nil)
        #expect(profiles.activate(try #require(profiles.owner)))
        let valid = await library.writeTags(TagEdits(album: "Allowed"), to: [try #require(library.tracks.first)])
        #expect(valid.isComplete && valid.written.count == 1)
    }
}


extension MetadataWriterTests {
    @Test func fillingMissingGenresReadsExistingTagsInsteadOfTrustingAStaleCache() async throws {
        let drive = fixtureDrive()
        var cached = track(mp3Path, title: "Morning")
        cached.genreTag = nil
        let original = await drive.files
        let report = await MetadataWriter().write(TagEdits(genre: "Dance"), to: [cached], drive: drive, onlyIfGenreMissing: true)
        #expect(report.written.isEmpty && report.failures.isEmpty)
        #expect(report.unchanged.first?.genreTag == "Rock")
        #expect(await drive.files == original)
        #expect(await drive.calls.isEmpty)
    }

    @Test func missingGenreIsWrittenWhileAudioBytesAndOtherTagsStayIntact() async throws {
        let noGenre = Data(mp3Bytes).replacingRockWithBlank()
        let drive = WriterFixtureDrive(files: [mp3Path: noGenre])
        let report = await MetadataWriter().write(TagEdits(genre: "Dance"), to: [track(mp3Path, title: "Morning")], drive: drive, onlyIfGenreMissing: true)
        #expect(report.written.count == 1 && report.failures.isEmpty)
        #expect(try await readTags(drive, mp3Path)?.genre == "Dance")
        #expect(try await readTags(drive, mp3Path)?.title == "Morning")
        #expect(await drive.files[mp3Path]?.suffix(417) == noGenre.suffix(417))
    }

    @Test func anotherClientsEditDuringUploadIsPreservedAndStagedCopyIsRemoved() async throws {
        let drive = fixtureDrive()
        let changed = Data(mp3Bytes) + Data([1, 2, 3])
        await drive.setOnUpload { await drive.setFile(mp3Path, changed) }
        let report = await MetadataWriter().write(TagEdits(genre: "Dance"), to: [track(mp3Path, title: "Morning")], drive: drive)
        #expect(report.written.isEmpty)
        #expect(report.failures.first?.message == RemoteWriteError.changed.localizedDescription)
        #expect(await drive.files[mp3Path] == changed)
        #expect(await drive.files.keys.allSatisfy { !$0.contains(".gumbo-") })
    }
}

private nonisolated extension Data {
    func replacingRockWithBlank() -> Data {
        var result = self
        if let range = result.range(of: Data("Rock".utf8)) { result.replaceSubrange(range, with: Data("    ".utf8)) }
        return result
    }
}

extension MetadataWriterTests {
    @Test func aGenreSuggestionForAnOlderFileVersionCannotChangeItsReplacement() async throws {
        let drive = fixtureDrive()
        var reviewed = track(mp3Path, title: "Morning")
        reviewed.genreTag = nil
        reviewed.sourceModifiedAt = 1_699_999_999
        let original = await drive.files
        let report = await MetadataWriter().write(TagEdits(genre: "Dance"), to: [reviewed], drive: drive, onlyIfGenreMissing: true)
        #expect(report.written.isEmpty)
        #expect(report.failures.first?.message == RemoteWriteError.changed.localizedDescription)
        #expect(await drive.files == original)
        #expect(await drive.calls.isEmpty)
    }
}

extension MetadataWriterTests {
    @Test(arguments: [false, true]) func renamingGuestCreditsWritesOneReleaseIdentityAndAFreshScanKeepsIt(compilation: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-rename-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await CoverStore.$directoryOverride.withValue(directory) {
            let oldTitle = "Muddy Days, Drunken Nights"
            let folder = "/music/Jawga Sparxx/" + oldTitle
            let albumArtist = compilation ? "Various Artists" : "Jawga Sparxx"
            let credits = compilation ? ["Singer One", "Singer Two", "Singer Three"]
                : ["Jawga Sparxx, Bubba Sparxxx", "Jawga Sparxx, Jawga Boyz", "Jawga Sparxx"]
            let id = Album.makeID(title: oldTitle, artist: albumArtist)
            let tracks = credits.enumerated().map { index, credit in
                let path = folder + "/\(index + 1).mp3"
                return Track(id: path, albumID: id, title: "Song \(index + 1)", index: index,
                             number: index + 1, disc: 1, duration: 100, codec: "mp3", path: path, format: "MP3",
                             artist: credit, albumTitleTag: oldTitle, albumArtistTag: credit, isEnriched: true)
            }
            let files = Dictionary(uniqueKeysWithValues: tracks.map { track in
                (track.id, Data(renameMP3(title: track.title, artist: track.artist!, album: oldTitle, number: track.number)))
            })
            let drive = WriterFixtureDrive(files: files)
            let album = Album(id: id, title: oldTitle, artist: albumArtist, year: 2023, genre: "Country",
                              tracks: tracks, colorA: "#000000", colorB: "#000000", addedRank: 0,
                              folderPath: folder, folderTitle: oldTitle, folderArtist: compilation ? "Unknown Artist" : albumArtist)
            let library = LibraryStore()
            library.replace(with: Catalogue(serverName: "Fixture", albums: [album], indexedAt: .now,
                                             rootPath: "/music", driveID: drive.id), drive: drive)
            let result = await library.renameAlbum(album, to: "Roadside Stories")
            #expect(result.report.isComplete && result.report.written.count == 3)
            #expect(library.catalogue.albums.count == 1)
            #expect(library.catalogue.albums.first?.artist == albumArtist)
            #expect(library.catalogue.albums.first?.tracks.compactMap(\.artist) == credits)
            let rewrittenFiles = await drive.files
            var entries: [RemoteEntry] = []
            for track in tracks { entries.append(try await drive.info(track.id)) }
            // A different device starts without the cached grouping and reads the NAS files.
            var fresh = Catalogue.build(folders: [ScannedFolder(path: folder, audio: entries, cover: nil)], rootPath: "/music",
                                        serverName: "Fixture", driveID: drive.id, existing: nil)
            for track in tracks {
                let tags = try #require(try await readTags(drive, track.id))
                #expect(tags.album == "Roadside Stories" && tags.albumArtist == albumArtist)
                #expect(tags.artist == track.artist)
                #expect(rewrittenFiles[track.id]?.suffix(417) == files[track.id]?.suffix(417))
                var probed = track
                probed.albumTitleTag = tags.album
                probed.albumArtistTag = tags.albumArtist
                fresh.apply(probed)
            }
            fresh.regroupByTags()
            #expect(fresh.albums.count == 1)
            #expect(fresh.albums.first?.id == result.albumID)
            #expect(fresh.albums.first?.tracks.compactMap(\.artist) == credits)

            // A stale cache can meet files that another device has already renamed. No second
            // upload is needed, but those verified tags must still reach the local catalogue.
            library.replace(with: Catalogue(serverName: "Fixture", albums: [album], indexedAt: .now,
                                             rootPath: "/music", driveID: drive.id), drive: drive)
            let again = await library.renameAlbum(album, to: "Roadside Stories")
            #expect(again.report.written.isEmpty && again.report.unchanged.count == 3)
            #expect(again.albumID == result.albumID)
            #expect(library.catalogue.albums.first?.title == "Roadside Stories")
            #expect(await drive.calls.count == 3)
        }
    }
}

private nonisolated func renameMP3(title: String, artist: String, album: String, number: Int) -> [UInt8] {
    func text(_ id: String, _ value: String) -> [UInt8] {
        let payload: [UInt8] = [0] + Array(value.utf8)
        return Array(id.utf8) + be32(payload.count) + [0, 0] + payload
    }
    let frames = text("TIT2", title) + text("TPE1", artist) + text("TPE2", artist) + text("TALB", album) + text("TRCK", String(number))
    let size = frames.count + 32
    let header = Array("ID3".utf8) + [UInt8(3), 0, 0] + TagWriter.syncsafeBytes(size)
    return header + frames + [UInt8](repeating: 0, count: 32) + Array(mp3Bytes.suffix(417))
}

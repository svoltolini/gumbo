import Foundation
import Testing
@testable import GumboCore

/// Synthetic FLAC streams and an in-memory drive; no NAS or real media is used.
private nonisolated func recoveryBE(_ value: Int, bytes: Int) -> [UInt8] {
    (0..<bytes).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
}

private nonisolated func recoveryLE32(_ value: Int) -> [UInt8] {
    [UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8((value >> 24) & 255)]
}

private nonisolated func recoveryBlock(_ type: Int, _ body: [UInt8], last: Bool = false) -> [UInt8] {
    [UInt8(type) | (last ? 0x80 : 0)] + recoveryBE(body.count, bytes: 3) + body
}

/// STREAMINFO for 96 kHz, 24-bit stereo, one minute long.
private nonisolated func recoveryStreamInfo() -> [UInt8] {
    let rate = 96_000, bits = 24, samples = 96_000 * 60
    var block = [UInt8](repeating: 0, count: 18)
    block[10] = UInt8((rate >> 12) & 255)
    block[11] = UInt8((rate >> 4) & 255)
    block[12] = UInt8((rate & 15) << 4) | UInt8(1 << 1) | UInt8(((bits - 1) >> 4) & 1)
    block[13] = UInt8(((bits - 1) & 15) << 4) | UInt8((samples >> 32) & 15)
    block[14...17] = ArraySlice(recoveryBE(samples & 0xFFFF_FFFF, bytes: 4))
    return block
}

private nonisolated func recoveryComments(_ fields: [String]) -> [UInt8] {
    let vendor = Array("fixture".utf8)
    return fields.reduce(recoveryLE32(vendor.count) + vendor + recoveryLE32(fields.count)) { result, field in
        result + recoveryLE32(field.utf8.count) + Array(field.utf8)
    }
}

private nonisolated func recoveryPicture(_ image: [UInt8]) -> [UInt8] {
    let mime = Array("image/png".utf8)
    return recoveryBE(3, bytes: 4) + recoveryBE(mime.count, bytes: 4) + mime + recoveryBE(0, bytes: 4)
        + recoveryBE(1, bytes: 4) + recoveryBE(1, bytes: 4) + recoveryBE(24, bytes: 4) + recoveryBE(0, bytes: 4)
        + recoveryBE(image.count, bytes: 4) + image
}

/// An ID3v2.4 tag of `size` zero bytes, as some taggers put in front of a FLAC stream.
private nonisolated func recoveryID3(size: Int, footer: Bool = false) -> [UInt8] {
    let syncsafe = [UInt8((size >> 21) & 127), UInt8((size >> 14) & 127), UInt8((size >> 7) & 127), UInt8(size & 127)]
    return Array("ID3".utf8) + [4, 0, footer ? 0x10 : 0] + syncsafe + [UInt8](repeating: 0, count: size)
        + (footer ? Array("3DI".utf8) + [4, 0, 0x10] + syncsafe : [])
}

private nonisolated func recoveryFLAC(title: String, pictureBytes: Int? = nil, pictureFirst: Bool = false) -> [UInt8] {
    let comments = recoveryBlock(4, recoveryComments(["TITLE=\(title)", "ARTIST=Tagged Artist"]))
    let picture = pictureBytes.map { recoveryBlock(6, recoveryPicture([UInt8](repeating: 7, count: $0))) } ?? []
    let padding = recoveryBlock(1, [0, 0, 0, 0], last: true)
    let blocks = pictureFirst ? picture + comments : comments + picture
    return Array("fLaC".utf8) + recoveryBlock(0, recoveryStreamInfo()) + blocks + padding + [0xFF, 0xF8, 0, 0]
}

private nonisolated func recoveryRead(_ bytes: [UInt8]) -> (Range<Int64>) async throws -> Data {
    { range in Data(bytes[min(bytes.count, Int(range.lowerBound))..<min(bytes.count, Int(range.upperBound))]) }
}

private nonisolated let recoveryImage = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!

private actor RecoveryDrive: RemoteDrive {
    let id = "indexing-recovery-fixture"
    let displayName = "Indexing recovery fixture"
    let tree: [String: [RemoteEntry]]
    let files: [String: [UInt8]]
    /// Thrown by every read and download, as when the connection drops during the pass.
    let failure: URLError.Code?
    private(set) var downloads: [String] = []

    init(tree: [String: [RemoteEntry]], files: [String: [UInt8]], failure: URLError.Code? = nil) {
        self.tree = tree
        self.files = files
        self.failure = failure
    }

    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { tree[path] ?? [] }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        if let failure { throw URLError(failure) }
        guard let bytes = files[path] else { throw URLError(.fileDoesNotExist) }
        return try await recoveryRead(bytes)(range)
    }
    func download(_ path: String, maxBytes: Int64) async throws -> Data {
        downloads.append(path)
        if let failure { throw URLError(failure) }
        guard let bytes = files[path] else { throw URLError(.fileDoesNotExist) }
        return Data(bytes)
    }
    nonisolated func streamURL(for path: String) -> URL? { nil }
}

private nonisolated func recoveryEntry(_ path: String, directory: Bool = false, size: Int = 4096) -> RemoteEntry {
    RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: directory,
                size: directory ? nil : Int64(size), modified: Date(timeIntervalSince1970: 1_700_000_000))
}

/// "Artist/Album" holding only the cover and the "CD1" and "CD2" folders with the songs.
private nonisolated func discFolderTree(song: [UInt8]) -> ([String: [RemoteEntry]], [String: [UInt8]]) {
    let album = "/music/Disc Artist/Two Disc Album"
    let songs = ["CD1", "CD2"].map { album + "/" + $0 + "/01 Song.flac" }
    let tree: [String: [RemoteEntry]] = [
        "/music": [recoveryEntry("/music/Disc Artist", directory: true)],
        "/music/Disc Artist": [recoveryEntry(album, directory: true)],
        album: [recoveryEntry(album + "/CD1", directory: true), recoveryEntry(album + "/CD2", directory: true),
                recoveryEntry(album + "/folder.jpg", size: recoveryImage.count)],
        album + "/CD1": [recoveryEntry(songs[0], size: song.count)],
        album + "/CD2": [recoveryEntry(songs[1], size: song.count)],
    ]
    var files = Dictionary(uniqueKeysWithValues: songs.map { ($0, song) })
    files[album + "/folder.jpg"] = [UInt8](recoveryImage)
    return (tree, files)
}

@MainActor private func recoveryScan(_ drive: RecoveryDrive, existing: Catalogue? = nil) async throws -> Catalogue {
    let indexer = LibraryIndexer(recordDiagnostics: { _ in })
    defer { indexer.cancel() }
    var latest: Catalogue?
    indexer.start(drive: drive, rootPath: "/music", serverName: "Fixture NAS", existing: existing) { latest = $0 }
    for _ in 0..<1000 {
        if !indexer.isRunning { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(indexer.phase == .done)
    return try #require(latest)
}

@MainActor private func withRecoveryCovers(_ body: @MainActor () async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-indexing-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await CoverStore.$directoryOverride.withValue(directory) { try await body() }
}

@Suite(.serialized) @MainActor struct IndexingRecoveryTests {
    // MARK: Album covers above disc folders (#241)

    @Test func discFoldersUseTheAlbumFolderCover() {
        let album = "/music/Artist/Album"
        let parentCover = recoveryEntry(album + "/folder.jpg")
        let discCover = recoveryEntry(album + "/CD2/scan.jpg")
        let folders = [
            ScannedFolder(path: album + "/CD1", audio: [recoveryEntry(album + "/CD1/01 A.flac")], cover: nil, parentCover: parentCover),
            ScannedFolder(path: album + "/CD2", audio: [recoveryEntry(album + "/CD2/01 B.flac")], cover: discCover, parentCover: parentCover),
        ]
        let catalogue = Catalogue.build(folders: folders, rootPath: "/music", serverName: "NAS", driveID: "fixture", existing: nil)
        #expect(catalogue.albums.count == 1)
        #expect(catalogue.albums.first?.coverPath == parentCover.path)

        // A disc folder's own picture is still used when the album folder has none.
        let withoutParent = [ScannedFolder(path: album + "/CD2", audio: [recoveryEntry(album + "/CD2/01 B.flac")], cover: discCover, parentCover: nil)]
        #expect(Catalogue.build(folders: withoutParent, rootPath: "/music", serverName: "NAS", driveID: "fixture", existing: nil)
            .albums.first?.coverPath == discCover.path)

        // Only disc folders reach up: an album inside an artist folder never takes the artist's picture.
        let plain = [ScannedFolder(path: album, audio: [recoveryEntry(album + "/01 A.flac")], cover: nil,
                                   parentCover: recoveryEntry("/music/Artist/artist.jpg"))]
        #expect(Catalogue.build(folders: plain, rootPath: "/music", serverName: "NAS", driveID: "fixture", existing: nil)
            .albums.first?.coverPath == nil)
    }

    @Test func scanFindsTheCoverBesideDiscFolders() async throws {
        try await withRecoveryCovers {
            let (tree, files) = discFolderTree(song: recoveryFLAC(title: "Song"))
            let drive = RecoveryDrive(tree: tree, files: files)
            let catalogue = try await recoveryScan(drive)
            let album = try #require(catalogue.albums.first)
            #expect(catalogue.albums.count == 1)
            #expect(album.tracks.count == 2)
            #expect(album.coverPath == "/music/Disc Artist/Two Disc Album/folder.jpg")
            #expect(try Data(contentsOf: CoverStore.fileURL(for: album.id)) == recoveryImage)
            #expect(CoverStore.missingCoverDate(for: album.id) == nil)
        }
    }

    // MARK: Connection failures are not "no cover" or a bad file (#242)

    @Test func droppedConnectionIsNeitherAMissingCoverNorAFailedRead() async throws {
        try await withRecoveryCovers {
            let (tree, files) = discFolderTree(song: recoveryFLAC(title: "Tagged Song"))
            let offline = try await recoveryScan(RecoveryDrive(tree: tree, files: files, failure: .networkConnectionLost))
            let album = try #require(offline.albums.first)
            #expect(!CoverStore.hasCover(for: album.id))
            #expect(CoverStore.missingCoverDate(for: album.id) == nil, "An interrupted search must not rest for a week")
            for track in album.tracks {
                #expect(!track.isEnriched)
                #expect(track.enrichAttempts == nil, "An interrupted read is not an attempt")
            }

            let online = RecoveryDrive(tree: tree, files: files)
            let recovered = try await recoveryScan(online, existing: offline)
            let refreshed = try #require(recovered.albums.first)
            #expect(refreshed.tracks.allSatisfy { $0.isEnriched && $0.title == "Tagged Song" })
            #expect(CoverStore.hasCover(for: refreshed.id))
            #expect(await online.downloads.contains("/music/Disc Artist/Two Disc Album/folder.jpg"))
        }
    }

    @Test func fileAnswersStillCountAsMissingCoverAndFailedRead() async throws {
        try await withRecoveryCovers {
            var (tree, _) = discFolderTree(song: [])
            tree["/music/Disc Artist/Two Disc Album"]?.removeAll { $0.name == "folder.jpg" }
            // The server says the songs are gone: that is an answer about the files.
            let catalogue = try await recoveryScan(RecoveryDrive(tree: tree, files: [:]))
            let album = try #require(catalogue.albums.first)
            #expect(CoverStore.missingCoverDate(for: album.id) != nil)
            #expect(album.tracks.allSatisfy { $0.enrichAttempts == 1 })
        }
    }

    @Test func onlyAnswersAboutTheFileAreRemembered() {
        #expect(URLError(.fileDoesNotExist).isAnswerAboutFile)
        #expect(SMBDriveError.missingPath.isAnswerAboutFile)
        #expect(SMBDriveError.permissionDenied.isAnswerAboutFile)
        #expect(WebDAVError.notFound.isAnswerAboutFile)
        #expect(RemoteDriveError.tooLarge.isAnswerAboutFile)
        #expect(SynologyError.api(code: 408, api: "SYNO.FileStation.Download").isAnswerAboutFile)
        #expect(!URLError(.timedOut).isAnswerAboutFile)
        #expect(!URLError(.networkConnectionLost).isAnswerAboutFile)
        #expect(!URLError(.notConnectedToInternet).isAnswerAboutFile)
        #expect(!SMBDriveError.disconnected.isAnswerAboutFile)
        #expect(!SMBDriveError.timedOut.isAnswerAboutFile)
        #expect(!SMBDriveError.shareUnavailable.isAnswerAboutFile)
        #expect(!RemoteDriveError.http(503).isAnswerAboutFile)
        #expect(!SynologyError.api(code: 119, api: "SYNO.FileStation.Download").isAnswerAboutFile)
        #expect(!CancellationError().isAnswerAboutFile)
    }

    // MARK: Large FLAC metadata and leading ID3 tags (#244)

    @Test func indexingKeepsTagsBesideAPictureTooLargeToRead() async throws {
        let bytes = recoveryFLAC(title: "Hi-Res Title", pictureBytes: 10 * 1024 * 1024)
        #expect(try await FLACHeader.read(read: recoveryRead(bytes)) == nil, "The tag writer still needs every block")
        let info = try #require(try await FLACHeader.read(requireAllBlocks: false, read: recoveryRead(bytes)))
        #expect(!info.isComplete)
        #expect(info.tag("TITLE") == "Hi-Res Title")
        #expect(info.sampleRate == 96_000)
        #expect(info.bitsPerSample == 24)
        #expect(info.duration == 60)
        #expect(info.picture == nil)
        // Comments behind the oversized picture cannot be reached; the indexer then asks AVFoundation.
        let behind = recoveryFLAC(title: "Unreachable", pictureBytes: 9 * 1024 * 1024, pictureFirst: true)
        #expect(try await FLACHeader.read(requireAllBlocks: false, read: recoveryRead(behind)) == nil)
        // A picture within the limit is still read.
        let small = try await FLACHeader.read(requireAllBlocks: false, read: recoveryRead(recoveryFLAC(title: "Small", pictureBytes: 1024)))
        #expect(small?.isComplete == true)
        #expect(small?.picture?.count == 1024)
    }

    @Test(arguments: [(3_000, false), (3_000, true), (600 * 1024, false)])
    func leadingID3TagIsSkipped(size: Int, footer: Bool) async throws {
        let bytes = recoveryID3(size: size, footer: footer) + recoveryFLAC(title: "After ID3")
        let info = try #require(try await FLACHeader.read(read: recoveryRead(bytes)))
        #expect(info.isComplete)
        #expect(info.tag("TITLE") == "After ID3")
        #expect(info.sampleRate == 96_000)
    }

    @Test func id3TaggedMP3AndMalformedID3AreNotFLAC() {
        let mp3 = recoveryID3(size: 100) + [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 100)
        #expect(FLACHeader.parse(Data(mp3)) == nil)
        let malformed = Array("ID3".utf8) + [4, 0, 0, 0x80, 0, 0, 0] + recoveryFLAC(title: "x")
        #expect(FLACHeader.parse(Data(malformed)) == nil)
        let long = recoveryID3(size: 600 * 1024) + recoveryFLAC(title: "x")
        #expect(FLACHeader.parse(Data(long.prefix(1000)))?.neededPrefix == 10 + 600 * 1024 + 8)
    }

    @Test func scanReadsFLACWithHugeEmbeddedCoverOrLeadingID3() async throws {
        try await withRecoveryCovers {
            let big = recoveryFLAC(title: "Big Cover Song", pictureBytes: 10 * 1024 * 1024)
            let prefixed = recoveryID3(size: 4096) + recoveryFLAC(title: "ID3 Song")
            let folder = "/music/Tagged Artist/Album"
            let tree: [String: [RemoteEntry]] = [
                "/music": [recoveryEntry("/music/Tagged Artist", directory: true)],
                "/music/Tagged Artist": [recoveryEntry(folder, directory: true)],
                folder: [recoveryEntry(folder + "/01 Big.flac", size: big.count), recoveryEntry(folder + "/02 Prefixed.flac", size: prefixed.count)],
            ]
            let catalogue = try await recoveryScan(RecoveryDrive(tree: tree, files: [folder + "/01 Big.flac": big, folder + "/02 Prefixed.flac": prefixed]))
            let tracks = catalogue.albums.flatMap(\.tracks).sorted { $0.fileName < $1.fileName }
            #expect(tracks.map(\.title) == ["Big Cover Song", "ID3 Song"])
            #expect(tracks.allSatisfy { $0.isEnriched && $0.duration == 60 && $0.sampleRate == 96_000 && $0.artist == "Tagged Artist" })
        }
    }
}

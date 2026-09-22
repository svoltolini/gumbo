import Foundation
import Testing
@testable import GumboCore

/// The Finder metadata macOS writes as "._name" beside every file it copies to a non-Mac volume.
private nonisolated let appleDouble = Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00] + [UInt8](repeating: 0, count: 4088))
private nonisolated let folderPicture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
private nonisolated let albumFolder = "/music/Real Artist/Album"

private nonisolated func fileEntry(_ path: String, size: Int64 = 4096) -> RemoteEntry {
    RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: false, size: size,
                modified: Date(timeIntervalSince1970: 1_700_000_000))
}

private nonisolated func folderEntry(_ path: String) -> RemoteEntry {
    RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: true, size: nil, modified: nil)
}

/// FLAC tags that credit the song to the album's artist, without an album-artist tag.
private nonisolated func taggedFLAC(number: Int) -> Data {
    func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 255) } }
    func header(_ kind: UInt8, _ length: Int) -> [UInt8] { [kind, UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)] }
    let comments = ["TITLE=Song \(number)", "ARTIST=Real Artist", "ALBUM=Album", "TRACKNUMBER=\(number)"].map { Array($0.utf8) }
    let body: [UInt8] = le32(0) + le32(comments.count) + comments.flatMap { le32($0.count) + $0 }
    let streamInfo: [UInt8] = header(0, 34) + [UInt8](repeating: 0, count: 34)
    return Data(Array("fLaC".utf8) + streamInfo + header(0x84, body.count) + body)
}

/// An album folder as macOS leaves it on an SMB share: every song and picture has a "._" twin,
/// which sorts before it.
private nonisolated func albumListing() -> [RemoteEntry] {
    var entries = [fileEntry(albumFolder + "/.DS_Store")]
    for number in 1...3 {
        entries.append(fileEntry("\(albumFolder)/._0\(number) - Song \(number).flac"))
        entries.append(fileEntry("\(albumFolder)/0\(number) - Song \(number).flac", size: 30_000_000))
    }
    entries.append(fileEntry(albumFolder + "/._Cover (Front).jpg"))
    entries.append(fileEntry(albumFolder + "/Cover (Front).jpg", size: Int64(folderPicture.count)))
    return entries
}

private nonisolated func albumContents() -> [String: Data] {
    var contents = [albumFolder + "/._Cover (Front).jpg": appleDouble, albumFolder + "/Cover (Front).jpg": folderPicture]
    for number in 1...3 {
        contents["\(albumFolder)/._0\(number) - Song \(number).flac"] = appleDouble
        contents["\(albumFolder)/0\(number) - Song \(number).flac"] = taggedFLAC(number: number)
    }
    return contents
}

private actor HiddenFileDrive: RemoteDrive {
    let id = "hidden-file-fixture"
    let displayName = "Hidden file fixture"
    let tree: [String: [RemoteEntry]] = [
        "/music": [folderEntry("/music/Real Artist")],
        "/music/Real Artist": [folderEntry(albumFolder)],
        albumFolder: albumListing(),
    ]
    let contents = albumContents()
    private(set) var reads: [String] = []
    private(set) var downloads: [String] = []

    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { tree[path] ?? [] }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        reads.append(path)
        guard let data = contents[path] else { throw URLError(.fileDoesNotExist) }
        let lower = min(data.count, Int(range.lowerBound))
        let upper = min(data.count, Int(range.upperBound))
        return data.subdata(in: lower..<upper)
    }
    func download(_ path: String, maxBytes: Int64) async throws -> Data {
        downloads.append(path)
        guard let data = contents[path] else { throw URLError(.fileDoesNotExist) }
        return data
    }
    nonisolated func streamURL(for path: String) -> URL? { nil }
}

@MainActor private func withCovers(_ body: @MainActor () async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-hidden-files-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await CoverStore.$directoryOverride.withValue(directory) { try await body() }
}

@MainActor private func scan(_ drive: HiddenFileDrive, existing: Catalogue?) async throws -> Catalogue {
    let indexer = LibraryIndexer(recordDiagnostics: { _ in })
    defer { indexer.cancel() }
    var latest: Catalogue?
    indexer.start(drive: drive, rootPath: "/music", serverName: "NAS", existing: existing) { latest = $0 }
    for _ in 0..<1000 {
        if !indexer.isRunning { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(indexer.phase == .done)
    return try #require(latest)
}

@Suite(.serialized) @MainActor struct HiddenFileTests {
    private let songNames = ["01 - Song 1.flac", "02 - Song 2.flac", "03 - Song 3.flac"]
    private let coverPath = albumFolder + "/Cover (Front).jpg"

    @Test func appleDoubleAndOtherDotFilesAreNeitherSongsNorCovers() {
        for name in ["._01 - Song.flac", ".hidden.mp3", "._Song.m4a", "._cover.jpg", "._folder.jpg", ".cover.png"] {
            let entry = fileEntry("/music/Album/" + name)
            #expect(entry.isHidden)
            #expect(!entry.isAudio, "\(name) is not music")
            #expect(!entry.isImage, "\(name) is not a cover")
        }
        #expect(fileEntry("/music/Album/01 - Song.flac").isAudio)
        #expect(fileEntry("/music/Album/folder.jpg").isImage)
        #expect(!fileEntry("/music/Album/folder.jpg").isHidden)
    }

    @Test func folderCoverIgnoresAppleDoubleTwins() {
        func pick(_ names: [String]) -> String? {
            RemoteDriveSupport.coverImage(in: names.map { fileEntry("/music/Album/" + $0) })?.name
        }
        #expect(pick(["._cover.jpg", "._folder.jpg", "folder.jpg"]) == "folder.jpg")
        // A twin sorts first: it used to win the name search and defeat the single-picture fallback.
        #expect(pick(["._Cover (Front).jpg", "Cover (Front).jpg"]) == "Cover (Front).jpg")
        #expect(pick(["._scan.jpg", "scan.jpg"]) == "scan.jpg")
        #expect(pick(["._cover.jpg", "._folder.jpg"]) == nil)
    }

    @Test func ghostsInAnOlderCatalogueAreNeverRewrittenInspectedOrDeleted() {
        #expect(!AlbumDeletionPaths.isSong("/music/Album/._01 - Song.flac", inside: "/music"))
        #expect(!AlbumDeletionPaths.isSong("/music/Album/.hidden.mp3", inside: "/music"))
        #expect(AlbumDeletionPaths.isSong("/music/Album/01 - Song.flac", inside: "/music"))
        let ghost = track("/music/Album/._01 - Song.flac")
        let damaged = track("/music/Album/01 - Song.flac")
        #expect(ghost.isHiddenFile)
        #expect(!damaged.isHiddenFile)
        #expect(!MusicFileInspector.needsInspection(ghost))
        #expect(MusicFileInspector.needsInspection(damaged))
    }

    @Test func droppedGhostsAreNotReportedAsServerDeletions() {
        let songs = (1...3).map { fileEntry("\(albumFolder)/0\($0) - Song \($0).flac") }
        let ghosts = (1...3).map { fileEntry("\(albumFolder)/._0\($0) - Song \($0).flac") }
        let previous = Catalogue.build(folders: [ScannedFolder(path: albumFolder, audio: songs + ghosts, cover: nil)],
                                       rootPath: "/music", serverName: "NAS", driveID: "fixture", existing: nil)
        #expect(previous.trackCount == 6)
        #expect(previous.removedTrackIDs(present: Set(songs.map(\.path))).isEmpty)
        #expect(previous.removedTrackIDs(present: Set(songs.prefix(2).map(\.path))) == [songs[2].path])
    }

    @Test func scanFindsEachSongOnceUnderItsArtistBesideAppleDoubleTwins() async throws {
        try await withCovers {
            let drive = HiddenFileDrive()
            let catalogue = try await scan(drive, existing: nil)
            let album = try #require(catalogue.albums.first)
            #expect(catalogue.albums.count == 1)
            #expect(album.tracks.map(\.fileName) == songNames)
            #expect(album.artist == "Real Artist")
            #expect(album.coverPath == coverPath)
            #expect(try Data(contentsOf: CoverStore.fileURL(for: album.id)) == folderPicture)
            let reads = await drive.reads
            #expect(!reads.isEmpty)
            #expect(!reads.contains { RemoteDriveSupport.isHidden(($0 as NSString).lastPathComponent) })
            #expect(await drive.downloads == [coverPath])
        }
    }

    @Test func libraryScannedWithGhostsHealsOnTheNextScan() async throws {
        try await withCovers {
            let drive = HiddenFileDrive()
            let listing = albumListing()
            let ghostCover = try #require(listing.first { $0.name == "._Cover (Front).jpg" })
            // What older builds made of the folder: every twin was a song, and one lent the cover.
            var previous = Catalogue.build(folders: [ScannedFolder(path: albumFolder, audio: listing.filter { $0.fileExtension == "flac" }, cover: ghostCover)],
                                           rootPath: "/music", serverName: "NAS", driveID: "hidden-file-fixture", existing: nil)
            for a in previous.albums.indices {
                for t in previous.albums[a].tracks.indices where !previous.albums[a].tracks[t].isHiddenFile {
                    previous.albums[a].tracks[t].isEnriched = true
                    previous.albums[a].tracks[t].tagVersion = Track.currentTagVersion
                    previous.albums[a].tracks[t].artist = "Real Artist"
                    previous.albums[a].tracks[t].albumTitleTag = "Album"
                    previous.albums[a].tracks[t].duration = 180
                }
            }
            previous.regroupByTags()
            let stale = try #require(previous.albums.first)
            #expect(previous.albums.count == 1)
            #expect(stale.tracks.count == 6)
            #expect(stale.artist == "Various Artists", "Half the credits were unique ghosts, so nobody had a majority")
            #expect(stale.coverPath == ghostCover.path)
            // The twin's bytes were stored for the folder's album and copied to the regrouped one.
            let folderAlbumID = Album.makeID(title: "Album", artist: "Real Artist")
            CoverStore.save(appleDouble, for: folderAlbumID)
            CoverStore.save(appleDouble, for: stale.id)

            let healed = try await scan(drive, existing: previous)
            let album = try #require(healed.albums.first)
            #expect(healed.albums.count == 1)
            #expect(album.tracks.map(\.fileName) == songNames)
            #expect(album.artist == "Real Artist")
            #expect(album.id == folderAlbumID)
            #expect(album.coverPath == coverPath)
            #expect(try Data(contentsOf: CoverStore.fileURL(for: album.id)) == folderPicture)
            #expect(!CoverStore.hasCover(for: stale.id))
            #expect(previous.removedTrackIDs(present: Set(healed.albums.flatMap(\.tracks).map(\.id))).isEmpty)
            #expect(await drive.reads.isEmpty, "Tags already read are kept, and the twins are never read")
            #expect(await drive.downloads == [coverPath])
        }
    }

    private func track(_ path: String) -> Track {
        Track(id: path, albumID: "album", title: "Song", index: 0, number: 1, disc: 1, duration: 0,
              codec: "flac", path: path, format: "FLAC", isEnriched: false)
    }
}

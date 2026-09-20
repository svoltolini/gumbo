import Foundation
import Testing
@testable import GumboCore

@Suite struct AuditMetadataTests {
    private func album(artist: String, title: String = "Greatest Hits", trackID: String) -> Album {
        let id = Album.makeID(title: title, artist: artist)
        let track = Track(id: trackID, albumID: id, title: "Song", index: 0, number: 1, disc: 1,
                          duration: 60, codec: "flac", sampleRate: nil, bitDepth: nil, bitrate: nil,
                          fileSize: nil, path: "/music/\(artist)/\(trackID).flac", format: "FLAC",
                          artist: artist, albumTitleTag: title, albumArtistTag: artist, isEnriched: true)
        return Album(id: id, title: title, artist: artist, year: 0, genre: "Unknown", label: nil,
                     tracks: [track], colorA: "#000000", colorB: "#000000", addedRank: 0,
                     folderPath: "/music/\(artist)", coverPath: nil, folderTitle: title, folderArtist: artist, folderYear: nil)
    }

    @Test func unrelatedArtistsKeepSeparateSameTitleAlbums() {
        let a = album(artist: "Artist A", trackID: "a")
        let b = album(artist: "Artist B", trackID: "b")
        let result = Catalogue.mergingSameTitles([a, b])
        #expect(result.count == 2)
        #expect(result.first(where: { $0.id == a.id })?.tracks.map(\.id) == ["a"])
        #expect(result.first(where: { $0.id == b.id })?.tracks.map(\.id) == ["b"])
    }

    @Test func sameArtistDiscFoldersStillCombine() {
        let result = Catalogue.mergingSameTitles([
            album(artist: "Artist A", trackID: "disc1"),
            album(artist: "artist a", trackID: "disc2"),
        ])
        #expect(result.count == 1)
        #expect(Set(result.flatMap(\.tracks).map(\.id)) == ["disc1", "disc2"])
    }

    @Test func nonfinalFLACBlockBoundaryRequestsTheNextHeader() throws {
        let bytes = Self.flacWithLargePadding()
        let first = try #require(FLACHeader.parse(Data(bytes.prefix(Int(FLACHeader.initialRead)))))
        let length = try #require(first.neededPrefix)
        let second = try #require(FLACHeader.parse(Data(bytes.prefix(length))))
        #expect((second.neededPrefix ?? 0) > length)
        #expect(FLACHeader.parse(Data(bytes))?.tag("TITLE") == "Hidden title")
    }

    @Test func completeFLACReaderReachesCommentsAfterLargePadding() async throws {
        let bytes = Self.flacWithLargePadding()
        let info = try await FLACHeader.read { range in
            Data(bytes[min(bytes.count, Int(range.lowerBound))..<min(bytes.count, Int(range.upperBound))])
        }
        #expect(info?.isComplete == true)
        #expect(info?.tag("TITLE") == "Hidden title")
        let truncated = Array(bytes.dropLast(4))
        let incomplete = try await FLACHeader.read { range in
            Data(truncated[min(truncated.count, Int(range.lowerBound))..<min(truncated.count, Int(range.upperBound))])
        }
        #expect(incomplete == nil)
    }

    @Test(arguments: [3, 4]) func unsynchronisedFramePreservesFollowingAlbum(version: UInt8) async throws {
        let payload: [UInt8] = [0, 0xFF, 0xE0]
        let stuffed: [UInt8] = [0, 0xFF, 0, 0xE0]
        func frame(_ id: String, _ body: [UInt8], size: Int? = nil, flags: UInt8 = 0) -> [UInt8] {
            Array(id.utf8) + Self.be32(size ?? body.count) + [0, flags] + body
        }
        let first = frame("TIT2", version == 3 ? payload : stuffed, flags: version == 4 ? 2 : 0)
        let second = frame("TALB", [0] + Array("Expected Album".utf8))
        var body = first + second
        if version == 3 {
            body = body.flatMap { $0 == 0xFF ? [$0, 0] : [$0] }
        }
        let file = Array("ID3".utf8) + [version, 0, version == 3 ? 0x80 : 0] + Self.be32(body.count) + body
        let media = try await ID3Tags.read(fileSize: Int64(file.count)) { range in
            Data(file[min(file.count, Int(range.lowerBound))..<min(file.count, Int(range.upperBound))])
        }
        #expect(media?.album == "Expected Album")
    }

    private static func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    }

    static func flacWithLargePadding() -> [UInt8] {
        func block(_ kind: UInt8, _ body: [UInt8]) -> [UInt8] {
            [kind] + Array(be32(body.count).suffix(3)) + body
        }
        let title = Array("TITLE=Hidden title".utf8)
        let comment: [UInt8] = [0, 0, 0, 0, 1, 0, 0, 0, UInt8(title.count), 0, 0, 0] + title
        return Array("fLaC".utf8) + block(0, [UInt8](repeating: 0, count: 34))
            + block(1, [UInt8](repeating: 0, count: 300_000)) + block(0x84, comment)
    }
}

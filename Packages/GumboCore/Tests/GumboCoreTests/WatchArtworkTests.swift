import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GumboCore

@Suite("Watch artwork")
struct WatchArtworkTests {
    private func catalogue() -> WatchCatalogue {
        let track = WatchTrack(id: "song", title: "Song", artist: "Artist", album: "Album", duration: 12,
                               path: "/music/song.mp3", fileSize: 100, format: "MP3", isLossless: false, albumID: "album")
        return WatchCatalogue(serverName: "NAS", profileName: "Me", playlists: [
            WatchPlaylist(id: "p", name: "Playlist", isSmart: false, coverColours: [], tracks: [track],
                          totalSongs: 1, driveID: "nas", profileID: "me")
        ])
    }

    @Test func olderCatalogueWithoutArtworkStillDecodes() throws {
        let encoded = try JSONEncoder().encode(catalogue())
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "artwork")
        var playlists = try #require(json["playlists"] as? [[String: Any]])
        var tracks = try #require(playlists[0]["tracks"] as? [[String: Any]])
        tracks[0].removeValue(forKey: "albumID")
        playlists[0]["tracks"] = tracks
        json["playlists"] = playlists
        let decoded = try JSONDecoder().decode(WatchCatalogue.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.artwork.isEmpty)
        #expect(decoded.playlists[0].tracks[0].albumID == nil)
    }

    @Test func decoderDropsUnreferencedAndOldPolicyArtwork() throws {
        var snapshot = catalogue()
        snapshot.artwork = ["album": Data([1, 2]), "another-nas": Data([3])]
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchCatalogue.self, from: encoded)
        #expect(decoded.artwork == ["album": Data([1, 2])])
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "artworkPolicyVersion")
        let old = try JSONDecoder().decode(WatchCatalogue.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.artwork.isEmpty)
    }

    @Test func payloadBudgetIsBoundedAndDeterministic() {
        var images = Dictionary(uniqueKeysWithValues: (0..<100).map { ("album-\($0)", Data(repeating: 1, count: 24_000)) })
        images["oversized"] = Data(repeating: 1, count: 24_001)
        images["empty"] = Data()
        let result = WatchArtwork.bounded(images, albumIDs: Set(images.keys))
        #expect(result.values.reduce(0) { $0 + $1.count } <= WatchArtwork.totalByteLimit)
        #expect(result.count == 20)
        #expect(result["oversized"] == nil)
        #expect(result["empty"] == nil)
        #expect(result == WatchArtwork.bounded(images, albumIDs: Set(images.keys)))
        let tiny = Dictionary(uniqueKeysWithValues: (0..<100).map { (String($0), Data([1])) })
        #expect(WatchArtwork.bounded(tiny, albumIDs: Set(tiny.keys)).count == WatchArtwork.albumLimit)
    }

    @Test func deletedAlbumArtworkIsRemovedAndContentKeysAreStable() {
        var snapshot = catalogue()
        snapshot.artwork = ["album": Data([1])]
        var same = snapshot
        same.generatedAt = .distantFuture
        #expect(snapshot.contentKey == same.contentKey)
        snapshot.applyServerDeletions(["nas": ["song"]])
        #expect(snapshot.artwork.isEmpty)
        #expect(snapshot.playlists[0].tracks.isEmpty)
    }

    @Test func builderUsesLocalFilesAndRefreshesCoverRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "watch-artwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "cover.png")
        try writeImage(to: url, red: 1, blue: 0)
        let builder = WatchArtworkBuilder()
        let source = WatchArtworkSource(albumID: "album", url: url, version: 1)
        let first = await builder.thumbnails(for: [source, source])
        let firstData = try #require(first["album"])
        #expect(first.count == 1)
        #expect(WatchArtwork.isThumbnail(firstData))
        #expect(firstData.count <= WatchArtwork.imageByteLimit)
        #expect(!WatchArtwork.isThumbnail(Data([1, 2, 3])))
        #expect(!WatchArtwork.isThumbnail(try Data(contentsOf: url)))
        try writeImage(to: url, red: 0, blue: 1)
        let updated = await builder.thumbnails(for: [WatchArtworkSource(albumID: "album", url: url, version: 2)])
        #expect(updated["album"] != firstData)
        // Even a reused local path and cover revision cannot reuse another authorization's image.
        try writeImage(to: url, red: 1, blue: 0)
        let changedScope = await builder.thumbnails(for: [WatchArtworkSource(albumID: "album", url: url, version: 2)], scope: "another-profile-and-nas")
        #expect(changedScope["album"] == firstData)
        let refused = await builder.thumbnails(for: [WatchArtworkSource(albumID: "remote", url: URL(string: "https://example.invalid/never-fetched")!, version: 1)])
        #expect(refused.isEmpty)
    }

    private func writeImage(to url: URL, red: CGFloat, blue: CGFloat) throws {
        let context = try #require(CGContext(data: nil, width: 1_024, height: 1_024, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 1_024))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

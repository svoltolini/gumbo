import Foundation
import Testing
@testable import GumboCore

@Suite struct WatchServerDeletionTests {
    private func playlist(source: String) -> WatchPlaylist {
        WatchPlaylist(id: "mix", name: "Mix", isSmart: false, coverColours: [], tracks: [
            WatchTrack(id: "song", title: "Song", artist: "Artist", album: "Album", duration: 120, path: "/music/Song.flac", fileSize: 20, format: "FLAC", isLossless: true)
        ], totalSongs: 1, driveID: source, profileID: "listener")
    }

    @Test func deletionsAreSourceScopedAndIdempotent() throws {
        var catalogue = WatchCatalogue(serverName: "NAS", profileName: "Me", playlists: [playlist(source: "one"), playlist(source: "two")])
        catalogue.serverSourceID = "one"
        catalogue.serverDeletionRevision = 4
        catalogue.applyServerDeletions(["one": ["song"]])
        catalogue.applyServerDeletions(["one": ["song"]])
        #expect(catalogue.playlists[0].tracks.isEmpty)
        #expect(catalogue.playlists[0].totalSongs == 0)
        #expect(catalogue.playlists[1].tracks.count == 1)
        #expect(catalogue.deletedCacheKeys == [DownloadManager.cacheKey(trackID: "song", driveID: "one")])
        let decoded = try JSONDecoder().decode(WatchCatalogue.self, from: JSONEncoder().encode(catalogue))
        #expect(decoded.serverDeletionRevision == 4)
        #expect(decoded.serverSourceID == "one")
        #expect(decoded.deletedCacheKeys == catalogue.deletedCacheKeys)
    }

    @Test func olderPhoneCataloguesDoNotImplyAnyDeletion() throws {
        let catalogue = WatchCatalogue(serverName: "NAS", profileName: "Me", playlists: [playlist(source: "one")])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalogue)) as? [String: Any])
        json.removeValue(forKey: "serverDeletedTrackIDs")
        json.removeValue(forKey: "serverDeletionRevision")
        json.removeValue(forKey: "serverSourceID")
        let decoded = try JSONDecoder().decode(WatchCatalogue.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.deletedCacheKeys.isEmpty)
        #expect(decoded.serverDeletionRevision == 0)
        #expect(decoded.playlists.first?.tracks.count == 1)
    }

    @Test func manifestRemovesOnlySourceMatchedSafePathsAndRetiresLateTransfers() {
        let generation = UUID()
        let removed = DownloadManager.cacheKey(trackID: "song", driveID: "one")
        let other = DownloadManager.cacheKey(trackID: "song", driveID: "two")
        var manifest = WatchDownloadManifest()
        manifest.files = ["song": "\(generation)/\(removed).flac", "otherSource": "\(generation)/\(other).flac", "bad": "../\(removed).flac"]
        manifest.generation = generation
        manifest.desired = ["song", "otherSource"]
        let result = manifest.removeServerFiles(deletedCacheKeys: [removed], removedTrackIDs: [])
        #expect(result.paths == ["\(generation)/\(removed).flac"])
        #expect(result.affected)
        #expect(manifest.generation == nil)
        #expect(manifest.files["song"] == nil)
        #expect(manifest.files["otherSource"] != nil && manifest.files["bad"] != nil)
        #expect(manifest.desired == ["otherSource"])
    }

    @Test func deletingPendingSongDoesNotRemoveOtherDownloadedSongs() {
        let generation = UUID()
        var manifest = WatchDownloadManifest()
        manifest.files = ["keep": "\(generation)/keep.flac"]
        manifest.desired = ["gone", "keep"]
        manifest.generation = generation
        let result = manifest.removeServerFiles(deletedCacheKeys: [], removedTrackIDs: ["gone"])
        #expect(result.affected && result.paths.isEmpty)
        #expect(manifest.files.count == 1 && manifest.desired == ["keep"])
        #expect(manifest.generation == nil)
    }
}

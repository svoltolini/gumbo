import Foundation
import Testing
@testable import GumboCore

@Suite @MainActor struct WatchArtworkSelectionTests {
    @Test func missingCoversDoNotSpendTheThumbnailBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "watch-art-selection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try CoverStore.$directoryOverride.withValue(directory) {
            let folders = (0...WatchArtwork.albumLimit).map { index in
                let path = "/music/Album \(index)"
                return ScannedFolder(path: path, audio: [
                    RemoteEntry(path: path + "/Song.mp3", name: "Song.mp3", isDirectory: false, size: 10, modified: nil),
                ], cover: nil)
            }
            let catalogue = Catalogue.build(folders: folders, rootPath: "/music", serverName: "Fixture",
                                             driveID: "art-selection-fixture", existing: nil)
            let lastAlbum = try #require(catalogue.albums.last)
            let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
            CoverStore.save(image, for: lastAlbum.id)
            let library = LibraryStore()
            library.replace(with: catalogue, drive: nil)
            let tracks = catalogue.albums.flatMap { album in
                album.tracks.map { track in
                    WatchTrack(id: track.id, title: track.title, artist: album.artist, album: album.title,
                               duration: 10, path: track.path!, fileSize: 10, format: "MP3", isLossless: false,
                               albumID: album.id)
                }
            }
            var snapshot = WatchCatalogue(serverName: "Fixture", profileName: "Fixture", playlists: [
                WatchPlaylist(id: "p", name: "Playlist", isSmart: false, coverColours: [], tracks: tracks,
                              totalSongs: tracks.count, driveID: catalogue.driveID, profileID: "fixture"),
            ])
            snapshot.serverSourceID = catalogue.driveID
            let selected = library.watchArtworkSources(for: snapshot)
            #expect(selected.map(\.albumID) == [lastAlbum.id], "The available cover after 64 missing ones must still be selected")
            snapshot.serverSourceID = "another-nas"
            #expect(library.watchArtworkSources(for: snapshot).isEmpty)
        }
    }
}

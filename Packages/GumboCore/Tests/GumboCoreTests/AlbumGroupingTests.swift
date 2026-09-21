import Foundation
import Testing
@testable import GumboCore

@Suite struct AlbumGroupingTests {
    private func album(_ artist: String, title: String = "A Radiant Sign", folder: String? = nil,
                       numbers: [Int], disc: Int = 1, tagged: Bool = true) -> Album {
        let folder = folder ?? "/music/\(title)"
        let id = Album.makeID(title: title, artist: artist)
        let tracks = numbers.map { number in
            let path = "\(folder)/\(number).m4a"
            return Track(id: path, albumID: id, title: "Song \(number)", index: number - 1,
                         number: number, disc: disc, duration: 120, codec: "alac", path: path, format: "ALAC",
                         artist: artist, albumTitleTag: title, albumArtistTag: tagged ? artist : nil,
                         isEnriched: true)
        }
        return Album(id: id, title: title, artist: artist, year: 2022, genre: "Electronic", tracks: tracks,
                     colorA: "#000000", colorB: "#000000", addedRank: 0, folderPath: folder,
                     folderTitle: (folder as NSString).lastPathComponent, folderArtist: "Unknown Artist")
    }

    private func regroup(_ albums: [Album], check: (Catalogue) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-grouping-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try CoverStore.$directoryOverride.withValue(directory) {
            var catalogue = Catalogue(serverName: "Fixture", albums: albums, indexedAt: .now, rootPath: "/music", driveID: "fixture")
            catalogue.regroupByTags()
            try check(catalogue)
            let first = catalogue.albums
            catalogue.regroupByTags()
            #expect(catalogue.albums == first, "Regrouping an already grouped catalogue must be stable")
        }
    }

    @Test func radiantSignRepairsAnAlreadySplitGuestTrackWithoutLosingCredits() throws {
        let guest = album("Nils Hoffmann & Niklas Paschburg", numbers: [1])
        let main = album("Nils Hoffmann", numbers: Array(2...13))
        try regroup([guest, main]) { catalogue in
            let combined = try #require(catalogue.albums.first)
            #expect(catalogue.albums.count == 1)
            #expect(combined.artist == "Nils Hoffmann")
            #expect(combined.tracks.map(\.number) == Array(1...13))
            #expect(combined.tracks.first?.artist == "Nils Hoffmann & Niklas Paschburg")
            #expect(Set(combined.tracks.map(\.id)) == Set((guest.tracks + main.tracks).map(\.id)))
            #expect(combined.tracks.allSatisfy { $0.albumID == combined.id })
        }
    }

    @Test @MainActor func regroupingPreservesFavouritesAndRecentAlbumsWithoutDuplicates() async throws {
        let guest = album("Nils Hoffmann & Niklas Paschburg", numbers: [1])
        let main = album("Nils Hoffmann", numbers: Array(2...13))
        var catalogue = Catalogue(serverName: "Fixture", albums: [guest, main], indexedAt: .now,
                                  rootPath: "/music", driveID: "fixture")
        let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        await CoverStore.$directoryOverride.withValue(directory) {
            let library = LibraryStore()
            library.replace(with: catalogue, drive: nil)
            library.notePlayed(main)
            library.notePlayed(guest)
            library.toggleFavourite(guest.tracks[0])
            catalogue.regroupByTags()
            library.replace(with: catalogue, drive: nil)
            await library.derivationTask?.value
            #expect(library.recentlyPlayedIDs == [main.id])
            #expect(library.recentlyPlayed.first?.tracks.count == 13)
            #expect(library.favouriteTracks.map(\.id) == [guest.tracks[0].id])
            #expect(library.favouriteTracks.first?.albumID == main.id)
        }
    }

    @Test func compilationWithTwoDifferentAlbumArtistsHasNoArbitraryWinner() throws {
        try regroup([album("Singer One", title: "Summer Mix", numbers: [1]),
                     album("Singer Two", title: "Summer Mix", numbers: [2])]) { catalogue in
            #expect(catalogue.albums.count == 1)
            #expect(catalogue.albums.first?.artist == "Various Artists")
            #expect(catalogue.trackCount == 2)
            var refreshed = try #require(catalogue.albums.first)
            refreshed.refreshFromTags()
            #expect(refreshed.artist == "Various Artists")
        }
    }

    @Test func compilationsWithoutAlbumArtistKeepEveryCredit() throws {
        try regroup([album("Singer One", title: "Summer Mix", numbers: [1], tagged: false),
                     album("Singer Two", title: "Summer Mix", numbers: [2], tagged: false),
                     album("Singer Three", title: "Summer Mix", numbers: [3], tagged: false)]) { catalogue in
            #expect(catalogue.albums.count == 1)
            #expect(catalogue.albums.first?.artist == "Various Artists")
            #expect(Set(catalogue.albums.flatMap(\.tracks).compactMap(\.artist)) == ["Singer One", "Singer Two", "Singer Three"])
        }
    }

    @Test func sameTitleInDifferentArtistFoldersStaysSeparate() throws {
        try regroup([album("Artist A", title: "Greatest Hits", folder: "/music/Artist A/Greatest Hits", numbers: [1]),
                     album("Artist B", title: "Greatest Hits", folder: "/music/Artist B/Greatest Hits", numbers: [1])]) { catalogue in
            #expect(catalogue.albums.count == 2)
            #expect(Set(catalogue.albums.map(\.artist)) == ["Artist A", "Artist B"])
        }
    }

    @Test func unrelatedSameTitleAlbumsInAMixedFolderStaySeparate() throws {
        try regroup([album("Artist A", title: "Greatest Hits", folder: "/music/Mixed", numbers: [1]),
                     album("Artist B", title: "Greatest Hits", folder: "/music/Mixed", numbers: [2])]) { catalogue in
            #expect(catalogue.albums.count == 2)
        }
    }

    @Test func discFoldersRegroupWithGuestCreditsAndKeepDiscOrder() throws {
        try regroup([album("Main Artist", title: "A Long Album", folder: "/music/A Long Album/CD1", numbers: [1, 2]),
                     album("Main Artist & Guest", title: "A Long Album", folder: "/music/A Long Album/CD2", numbers: [1], disc: 2)]) { catalogue in
            let combined = try #require(catalogue.albums.first)
            #expect(catalogue.albums.count == 1)
            #expect(combined.artist == "Main Artist")
            #expect(combined.tracks.map(\.disc) == [1, 1, 2])
            #expect(combined.tracks.map(\.index) == [0, 1, 2])
        }
    }

    @Test func yearAndArtistFolderPrefixesStillIdentifyOneRelease() throws {
        try regroup([album("Main Artist", folder: "/music/2022 - Main Artist - A Radiant Sign", numbers: [1, 2]),
                     album("Main Artist & Guest", folder: "/music/2022 - Main Artist - A Radiant Sign", numbers: [3])]) { catalogue in
            #expect(catalogue.albums.count == 1)
        }
    }
}

extension AlbumGroupingTests {
    @Test func renamedMuddyDaysRepairsCachedSplitsAndPreservesSongCredits() throws {
        let folder = "/music/Muddy Days, Drunken Nights"
        let guest = album("Jawga Sparxx, Bubba Sparxxx", title: "Muddy Days", folder: folder, numbers: [1])
        let other = album("Jawga Sparxx, Jawga Boyz", title: "Muddy Days", folder: folder, numbers: [2])
        let main = album("Jawga Sparxx", title: "Muddy Days", folder: folder, numbers: [3, 4])
        try regroup([guest, other, main]) { catalogue in
            let combined = try #require(catalogue.albums.first)
            #expect(catalogue.albums.count == 1)
            #expect(combined.title == "Muddy Days" && combined.artist == "Jawga Sparxx")
            #expect(combined.tracks.map(\.number) == [1, 2, 3, 4])
            #expect(combined.tracks.map(\.artist) == (guest.tracks + other.tracks + main.tracks).map(\.artist))
            #expect(combined.tracks.map(\.albumArtistTag) == (guest.tracks + other.tracks + main.tracks).map(\.albumArtistTag))
            #expect(Set(combined.tracks.map(\.albumID)) == [combined.id])
        }
    }

    @Test func sharedGuestInMixedFolderDoesNotEstablishAnAlbum() throws {
        try regroup([album("Artist A, Guest", title: "Greatest Hits", folder: "/music/Mixed", numbers: [1]),
                     album("Artist B, Guest", title: "Greatest Hits", folder: "/music/Mixed", numbers: [2])]) { catalogue in
            #expect(catalogue.albums.count == 2)
        }
    }

    @Test func overlappingTrackNumbersDoNotEstablishARenamedRelease() throws {
        let first = album("Artist A", title: "Greatest Hits", folder: "/music/Greatest Hits Collection", numbers: [1])
        var second = album("Artist A, Other", title: "Greatest Hits", folder: "/music/Greatest Hits Collection", numbers: [2])
        second.tracks[0].number = 1
        try regroup([first, second]) { catalogue in #expect(catalogue.albums.count == 2) }
    }

    @Test func rootFolderIsNotEvidenceForARenamedRelease() throws {
        try regroup([album("Artist A, Guest", title: "Greatest Hits", folder: "/music", numbers: [1]),
                     album("Artist A, Other", title: "Greatest Hits", folder: "/music", numbers: [2])]) { catalogue in
            #expect(catalogue.albums.count == 2)
        }
    }

    @Test func repairedGroupingSurvivesCatalogueReload() throws {
        let folder = "/music/Second Light Sessions"
        var cached = Catalogue(serverName: "Fixture", albums: [
            album("Main, Guest", title: "Second Light", folder: folder, numbers: [1]),
            album("Main", title: "Second Light", folder: folder, numbers: [2])
        ], indexedAt: .now, rootPath: "/music", driveID: "fixture")
        cached = try JSONDecoder().decode(Catalogue.self, from: JSONEncoder().encode(cached))
        try regroup(cached.albums) { catalogue in
            #expect(catalogue.albums.count == 1)
            #expect(catalogue.albums.first?.artist == "Main")
        }
    }
}


extension AlbumGroupingTests {
    @Test func separateCollaborationsInMixedFolderDoNotMergeWithInferredPositions() throws {
        try regroup([album("Artist A & Artist B", title: "Same Title", folder: "/music/Mixed", numbers: [1]),
                     album("Artist A & Artist C", title: "Same Title", folder: "/music/Mixed", numbers: [2]),
                     album("Artist A", title: "Same Title", folder: "/music/Mixed", numbers: [3])]) { catalogue in
            #expect(catalogue.albums.count == 3)
        }
    }

    @Test func shortenedTitleWithOnlyDifferentCollaborationCreditsStaysSeparate() throws {
        let folder = "/music/Shared Title Collection"
        try regroup([album("Artist A & Artist B", title: "Shared Title", folder: folder, numbers: [1]),
                     album("Artist A & Artist C", title: "Shared Title", folder: folder, numbers: [2])]) { catalogue in
            #expect(catalogue.albums.count == 2)
        }
    }
}

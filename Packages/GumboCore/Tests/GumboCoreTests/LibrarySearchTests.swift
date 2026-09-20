import Foundation
import Testing
@testable import GumboCore

@Suite("Library search")
struct LibrarySearchTests {
    @MainActor private func library() -> LibraryStore {
        var catalogue = SampleLibrary.catalogue
        catalogue.albums = Array(catalogue.albums.prefix(2))
        catalogue.albums[0].title = "L'Été Bleu"
        catalogue.albums[0].artist = "Beyoncé"
        catalogue.albums[0].genre = "Soul"
        catalogue.albums[0].tracks = Array(catalogue.albums[0].tracks.prefix(1))
        catalogue.albums[0].tracks[0].title = "Déjà Vu"
        catalogue.albums[0].tracks[0].artist = "Guest Singer"
        catalogue.albums[1].title = "Northern Lights"
        catalogue.albums[1].artist = "Another Artist"
        catalogue.albums[1].genre = "Electronic"
        catalogue.albums[1].tracks = Array(catalogue.albums[1].tracks.prefix(1))
        catalogue.albums[1].tracks[0].title = "Beyonce"
        catalogue.albums[1].tracks[0].artist = nil
        let store = LibraryStore()
        store.replace(with: catalogue, drive: nil)
        return store
    }

    @Test @MainActor func matchesAccentsCaseWidthAndWordsAcrossMetadata() async {
        let store = library()
        #expect(store.searchResults("BEYONCE").artists.map(\.name) == ["Beyoncé"])
        #expect(store.searchResults("ＢＥＹＯＮＣＥ").albums.map(\.title) == ["L'Été Bleu"])
        #expect(store.searchResults("  bleu   beyonce ").albums.map(\.title) == ["L'Été Bleu"])
        #expect(store.searchResults("beyonce deja").tracks.map(\.title) == ["Déjà Vu"])
        #expect(store.searchResults("singer ete").tracks.map(\.title) == ["Déjà Vu"])
        #expect(store.searchResults("soul").tracks.map(\.title) == ["Déjà Vu"])
        #expect(store.searchResults("deja missing").isEmpty)
        let background = await store.searchIndex.resultsInBackground(for: "beyonce deja")
        #expect(background.tracks.map(\.title) == ["Déjà Vu"])
    }

    @Test @MainActor func exactSongTitleRanksBeforeArtistMetadata() {
        #expect(library().searchResults("beyonce").tracks.map(\.title) == ["Beyonce", "Déjà Vu"])
    }

    @Test @MainActor func emptyAndPunctuationOnlyQueriesReturnNothing() {
        let store = library()
        for query in ["", " \n ", "---!!!"] {
            #expect(store.searchResults(query).isEmpty)
        }
    }

    @Test @MainActor func cancelledBackgroundSearchDoesNotPublishResults() async {
        let snapshot = library().searchIndex
        let task = Task { await snapshot.resultsInBackground(for: "beyonce") }
        task.cancel()
        #expect(await task.value.isEmpty)
    }

    @Test @MainActor func newRootPublishesItsIndexAndOldSnapshotsStayImmutable() async {
        let store = library()
        let previous = store.searchIndex
        let oldRevision = store.contentRevision
        var replacement = store.catalogue
        replacement.rootPath = "/another-music-folder"
        replacement.albums[0].tracks[0].title = "Replacement Song"
        store.replace(with: replacement, drive: nil)
        await store.derivationTask?.value
        #expect(store.contentRootPath == replacement.rootPath)
        #expect(store.contentRevision > oldRevision)
        #expect(store.searchResults("deja").isEmpty)
        #expect(store.searchResults("replacement").tracks.count == 1)
        let old = await previous.resultsInBackground(for: "deja")
        #expect(old.tracks.map(\.title) == ["Déjà Vu"])
    }

    @Test @MainActor func profileNavigationResetClearsThePreviousQuery() {
        let model = AppModel(library: library())
        model.searchQuery = "Private previous query"
        model.clearProfileNavigation()
        #expect(model.searchQuery.isEmpty)
    }
}

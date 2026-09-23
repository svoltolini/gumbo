import Foundation
import Testing
@testable import GumboCore

@Suite("Library browsing")
struct LibraryBrowsingTests {
    @Test @MainActor func artistsDifferingOnlyInCaseOrAccentsAreOneArtist() {
        var catalogue = SampleLibrary.catalogue
        catalogue.albums = Array(catalogue.albums.prefix(4))
        catalogue.albums[0].artist = "Pink Floyd"
        catalogue.albums[1].artist = "PINK FLOYD"
        catalogue.albums[2].artist = "Pink Floyd"
        catalogue.albums[3].artist = "Pínk Floyd"
        let store = LibraryStore()
        store.replace(with: catalogue, drive: nil)
        #expect(store.artists.count == 1)
        #expect(store.artists.first?.name == "Pink Floyd")
        #expect(store.artists.first?.albums.count == 4)
        #expect(store.artist(named: "PINK FLOYD")?.name == "Pink Floyd")
        #expect(store.artist(named: "Pink Floyd")?.albums.count == 4)
    }

    @Test func lettersFoldAccentsAndCaseAndGroupTheRestUnderHash() {
        #expect(AlphabeticalIndex.letter(for: "abba") == "A")
        #expect(AlphabeticalIndex.letter(for: "  Émilie Simon") == "E")
        #expect(AlphabeticalIndex.letter(for: "2Pac") == "#")
        #expect(AlphabeticalIndex.letter(for: "") == "#")
        #expect(AlphabeticalIndex.letter(for: "Ωmega") == "#")
    }

    @Test func groupsAreAlphabeticalWithHashLastAndKeepOrder() {
        let names = ["2Pac", "beta", "Alpha", "Bravo", "Émile", "!!!"]
        let groups = AlphabeticalIndex.groups(names) { $0 }
        #expect(groups.map { $0.letter } == ["A", "B", "E", "#"])
        #expect(groups[1].elements == ["beta", "Bravo"])
        #expect(groups[3].elements == ["2Pac", "!!!"])
    }

    @Test func pagesCoverEveryElementWithinTheLimit() {
        #expect(AlphabeticalIndex.pages(count: 0, size: 100).isEmpty)
        #expect(AlphabeticalIndex.pages(count: 100, size: 100) == [0..<100])
        #expect(AlphabeticalIndex.pages(count: 250, size: 100) == [0..<100, 100..<200, 200..<250])
    }
}

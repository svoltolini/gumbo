import Foundation

/// Immutable search data prepared with a catalogue revision, safe to query away from the UI actor.
public nonisolated struct LibrarySearchIndex: Sendable {
    private struct Entry<Item: Sendable>: Sendable {
        let item: Item
        let title: String
        let text: String

        init(_ item: Item, title: String, details: String) {
            self.item = item
            self.title = LibrarySearchIndex.normalize(title)
            self.text = LibrarySearchIndex.normalize(title + " " + details)
        }
    }

    private var artists: [Entry<Artist>] = []
    private var albums: [Entry<Album>] = []
    private var tracks: [Entry<Track>] = []

    public init(albums: [Album] = [], artists: [Artist] = []) {
        self.artists = artists.map { Entry($0, title: $0.name, details: "") }
        self.albums = albums.map { Entry($0, title: $0.title, details: "\($0.artist) \($0.genre) \($0.year)") }
        self.tracks = albums.flatMap { album in
            album.tracks.map { track in
                Entry(track, title: track.title, details: "\(track.artist ?? album.artist) \(album.artist) \(album.title) \(album.genre)")
            }
        }
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public func results(for query: String) -> SearchResults {
        let phrase = Self.normalize(query)
        guard !phrase.isEmpty, !Task.isCancelled else { return SearchResults() }
        let words = phrase.split(separator: " ").map(String.init)
        var result = SearchResults()
        result.artists = matches(artists, phrase: phrase, words: words, limit: 20)
        result.albums = matches(albums, phrase: phrase, words: words, limit: 30)
        result.tracks = matches(tracks, phrase: phrase, words: words, limit: 50)
        return Task.isCancelled ? SearchResults() : result
    }

    @concurrent public func resultsInBackground(for query: String) async -> SearchResults {
        results(for: query)
    }

    private func matches<Item>(_ entries: [Entry<Item>], phrase: String, words: [String], limit: Int) -> [Item] {
        // Keep a bounded set in each rank rather than sorting every matching song in a large library.
        var ranked = [[Item]](repeating: [], count: 4)
        for entry in entries {
            guard !Task.isCancelled else { return [] }
            guard words.allSatisfy({ entry.text.contains($0) }) else { continue }
            let rank: Int
            if entry.title == phrase { rank = 0 }
            else if entry.title.hasPrefix(phrase) { rank = 1 }
            else if words.allSatisfy({ entry.title.contains($0) }) { rank = 2 }
            else { rank = 3 }
            if ranked[rank].count < limit { ranked[rank].append(entry.item) }
        }
        return Array(ranked.flatMap { $0 }.prefix(limit))
    }
}

/// Query identity includes the published content and active source, not scan-progress changes.
public nonisolated struct LibrarySearchRequest: Equatable, Sendable {
    public let text: String
    public let revision: Int
    public let source: String
    public let root: String

    public init(text: String, revision: Int, source: String, root: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.revision = revision
        self.source = source
        self.root = root
    }
}

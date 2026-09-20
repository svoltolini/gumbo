import Foundation

/// A suggestion is not a tag edit. The person reviews it before any music file changes.
public nonisolated struct GenreSuggestion: Sendable, Equatable {
    public let genre: String
    public let album: String
    public let artist: String
    public let sourceURL: URL
}

public nonisolated enum GenreLookupError: LocalizedError {
    case unavailable
    public var errorDescription: String? { "Genre lookup is unavailable right now. Try again later, or enter a genre yourself." }
}

/// Explicit, text-only catalogue lookup. No music, file paths or NAS credentials leave the device.
public actor GenreLookup {
    public static let shared = GenreLookup()
    private let session: URLSession
    private var nextRequest = Date.distantPast
    private var cache: [String: GenreSuggestion] = [:]

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    public func suggestion(album: String, artist: String) async throws -> GenreSuggestion? {
        guard Self.canSearch(album: album, artist: artist) else { return nil }
        let key = Self.normalized(artist) + "\u{1F}" + Self.normalized(album)
        if let found = cache[key] { return found }
        // Apple's documented allowance is approximately twenty requests per minute.
        // Reserve before suspending so concurrent windows share the same allowance.
        let start = max(Date.now, nextRequest)
        nextRequest = start.addingTimeInterval(3.2)
        if start > .now { try await Task.sleep(for: .seconds(start.timeIntervalSinceNow)) }
        try Task.checkCancellation()
        let region = Locale.current.region?.identifier ?? "US"
        let country = region.count == 2 && region.allSatisfy(\.isLetter) ? region : "US"
        var url = URLComponents(string: "https://itunes.apple.com/search")!
        url.queryItems = [URLQueryItem(name: "term", value: artist + " " + album),
                          URLQueryItem(name: "entity", value: "album"), URLQueryItem(name: "media", value: "music"),
                          URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "country", value: country)]
        let (data, response) = try await session.data(from: url.url!)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 2_000_000 else {
            throw GenreLookupError.unavailable
        }
        let found = try Self.match(data: data, album: album, artist: artist)
        if let found { cache[key] = found }
        return found
    }

    public nonisolated static func isMissing(_ genre: String?) -> Bool {
        let value = (genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["", "unknown", "unknown genre", "no genre"].contains(value)
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated static func canSearch(album: String, artist: String) -> Bool {
        !normalized(album).isEmpty && !["", "unknown artist", "unknown", "spotify"].contains(normalized(artist))
            && !(album.count >= 24 && album.allSatisfy(\.isHexDigit))
    }

    private nonisolated struct Response: Decodable { let results: [Item] }
    private nonisolated struct Item: Decodable {
        let collectionName: String?
        let artistName: String?
        let primaryGenreName: String?
        let collectionViewUrl: String?
    }

    /// Exact normalized album AND full artist credit; no fuzzy/artist-only or deluxe/remix guesses.
    nonisolated static func match(data: Data, album: String, artist: String) throws -> GenreSuggestion? {
        let items = try JSONDecoder().decode(Response.self, from: data).results
        let matches = items.filter {
            normalized($0.collectionName ?? "") == normalized(album)
                && normalized($0.artistName ?? "") == normalized(artist)
                && !isMissing($0.primaryGenreName) && normalized($0.primaryGenreName ?? "") != "music"
        }
        guard Set(matches.compactMap(\.primaryGenreName).map(normalized)).count == 1,
              let item = matches.first, let genre = item.primaryGenreName,
              let source = item.collectionViewUrl, let url = URL(string: source),
              url.scheme == "https", url.host == "music.apple.com" else { return nil }
        return GenreSuggestion(genre: genre, album: item.collectionName ?? album,
                               artist: item.artistName ?? artist, sourceURL: url)
    }
}

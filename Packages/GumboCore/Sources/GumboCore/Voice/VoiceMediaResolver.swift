import CryptoKit
import Foundation

public nonisolated enum VoiceMediaKind: String, Sendable {
    case any, song, album, artist, playlist
}

public nonisolated struct VoiceMediaQuery: Sendable {
    public var kind: VoiceMediaKind
    public var name: String
    public var artist: String?
    public var album: String?

    public init(kind: VoiceMediaKind = .any, name: String, artist: String? = nil, album: String? = nil) {
        self.kind = kind
        self.name = name
        self.artist = artist
        self.album = album
    }
}

public nonisolated struct VoiceMediaMatch: Sendable {
    public let id: String
    public let kind: VoiceMediaKind
    public let title: String
    public let subtitle: String
    public let tracks: [Track]
    let artistNames: [String]
    let albumName: String?
}

/// Exact catalogue metadata only. Never guess a different recording when several titles match.
public nonisolated enum VoiceMediaResolver {
    public static func matches(_ query: VoiceMediaQuery, albums: [Album], playlists: [Playlist]) -> [VoiceMediaMatch] {
        let name = normalized(query.name)
        guard !name.isEmpty else { return [] }
        let artist = query.artist.map(normalized).flatMap { $0.isEmpty ? nil : $0 }
        let album = query.album.map(normalized).flatMap { $0.isEmpty ? nil : $0 }
        let candidates = all(albums: albums, playlists: playlists).filter { candidate in
            (query.kind == .any || candidate.kind == query.kind)
                && (artist == nil || candidate.artistNames.contains { normalized($0) == artist })
                && (album == nil || candidate.albumName.map(normalized) == album)
        }
        let exact = candidates.filter { normalized($0.title) == name }
        if !exact.isEmpty { return exact }
        // App Shortcuts receive a single utterance, while SiriKit supplies separate artist fields.
        // Only interpret "by" after trying the literal title (which may itself contain that word).
        return candidates.filter { candidate in
            candidate.artistNames.contains { normalized(candidate.title + " by " + $0) == name }
        }
    }

    public static func all(albums: [Album], playlists: [Playlist]) -> [VoiceMediaMatch] {
        var result: [VoiceMediaMatch] = []
        var songs = Set<String>()
        var artistTracks: [String: [Track]] = [:]
        var artistNames: [String: String] = [:]
        var artistTrackIDs: [String: Set<String>] = [:]
        for album in albums {
            result.append(VoiceMediaMatch(id: "album:" + album.id, kind: .album, title: album.title,
                                         subtitle: album.artist + " · Album", tracks: album.tracks,
                                         artistNames: [album.artist], albumName: album.title))
            for track in album.tracks {
                let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
                let credit = artist.flatMap { $0.isEmpty ? nil : $0 } ?? album.artist
                if songs.insert(track.id).inserted {
                    result.append(VoiceMediaMatch(id: "song:" + track.id, kind: .song, title: track.title,
                                                 subtitle: credit + " · " + album.title, tracks: [track],
                                                 artistNames: [credit, album.artist], albumName: album.title))
                }
                // Include the album artist and exact song credit; do not split band names at "&".
                for name in Set([credit, album.artist]) where !normalized(name).isEmpty {
                    let key = normalized(name)
                    artistNames[key] = name
                    if artistTrackIDs[key, default: []].insert(track.id).inserted {
                        artistTracks[key, default: []].append(track)
                    }
                }
            }
        }
        for key in artistTracks.keys.sorted() {
            let name = artistNames[key] ?? key
            result.append(VoiceMediaMatch(id: "artist:" + key, kind: .artist, title: name,
                                         subtitle: "Artist", tracks: artistTracks[key] ?? [],
                                         artistNames: [name], albumName: nil))
        }
        result += playlists.map {
            VoiceMediaMatch(id: "playlist:" + $0.id, kind: .playlist, title: $0.name,
                            subtitle: "Playlist · \($0.tracks.count) songs", tracks: $0.tracks,
                            artistNames: [], albumName: nil)
        }
        return result.filter { !$0.tracks.isEmpty }.sorted {
            ($0.title, $0.subtitle, $0.id) < ($1.title, $1.subtitle, $1.id)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public nonisolated enum VoicePlaybackError: Error, LocalizedError, Equatable {
    case openApp, noMatch, changed, offline, cancelled, playbackFailed, unsupported
    public var errorDescription: String? {
        switch self {
        case .openApp: "Open Gumbo and unlock your profile before asking Siri to play music."
        case .noMatch: "That music wasn’t found in your Gumbo library. Try its song, album, artist or playlist name."
        case .changed: "Your library or profile changed. Please ask again."
        case .offline: "Your music server isn’t available. Reconnect, or choose music downloaded to this device."
        case .cancelled: "The music request was cancelled."
        case .playbackFailed: "Gumbo couldn’t open that music. Open the app to check your server connection."
        case .unsupported: "Gumbo can play songs, albums, artists and playlists from your library."
        }
    }
}

public nonisolated struct VoicePlaybackContext: Equatable, Sendable {
    public let sourceID: String
    public let rootPath: String
    public let profileID: String
    public let sessionID: UUID
    public let connectionToken: UUID
    public let contentRevision: Int
    public init(sourceID: String, rootPath: String, profileID: String, sessionID: UUID, connectionToken: UUID, contentRevision: Int = 0) {
        self.sourceID = sourceID; self.rootPath = rootPath; self.profileID = profileID
        self.sessionID = sessionID; self.connectionToken = connectionToken
        self.contentRevision = contentRevision
    }

    func identifier(for match: VoiceMediaMatch) -> String {
        // Persistable shortcuts stay bound to one account/root/profile without exposing NAS paths.
        let data = (try? JSONEncoder().encode([sourceID, rootPath, profileID, match.id])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Catalogue updates may settle during launch; authentication and connection changes must not.
    func hasSameAccess(as other: Self) -> Bool {
        sourceID == other.sourceID && rootPath == other.rootPath && profileID == other.profileID
            && sessionID == other.sessionID && connectionToken == other.connectionToken
    }
}

public nonisolated struct VoiceMediaSelection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: VoiceMediaKind
    let matchID: String
    let context: VoicePlaybackContext

    init(_ match: VoiceMediaMatch, context: VoicePlaybackContext) {
        id = context.identifier(for: match); title = match.title; subtitle = match.subtitle
        kind = match.kind; matchID = match.id; self.context = context
    }
}

/// Shared by SiriKit and App Shortcuts. Closures make suspended request races testable without a NAS.
@MainActor public final class VoicePlaybackController {
    private let context: () -> VoicePlaybackContext?
    private let content: () -> (albums: [Album], playlists: [Playlist])
    private let isDownloaded: (Track) -> Bool
    private let isConnected: () -> Bool
    private let waitForConnection: @MainActor () async -> Void
    private let beginCommand: () -> UUID
    private let currentCommand: () -> UUID
    private let play: ([Track], String, Bool?, PlayerModel.RepeatMode?) -> Bool

    public init(context: @escaping () -> VoicePlaybackContext?, content: @escaping () -> (albums: [Album], playlists: [Playlist]),
                isDownloaded: @escaping (Track) -> Bool, isConnected: @escaping () -> Bool,
                waitForConnection: @escaping @MainActor () async -> Void, beginCommand: @escaping () -> UUID,
                currentCommand: @escaping () -> UUID, play: @escaping ([Track], String, Bool?, PlayerModel.RepeatMode?) -> Bool) {
        self.context = context; self.content = content; self.isDownloaded = isDownloaded
        self.isConnected = isConnected; self.waitForConnection = waitForConnection
        self.beginCommand = beginCommand; self.currentCommand = currentCommand; self.play = play
    }

    public func resolve(_ query: VoiceMediaQuery) async throws -> [VoiceMediaSelection] {
        try await selections { albums, playlists, context in
            VoiceMediaResolver.matches(query, albums: albums, playlists: playlists)
                .map { VoiceMediaSelection($0, context: context) }
        }
    }

    public func selections(for identifiers: [String]) async throws -> [VoiceMediaSelection] {
        let wanted = Set(identifiers)
        return try await selections { albums, playlists, context in
            VoiceMediaResolver.all(albums: albums, playlists: playlists)
                .map { VoiceMediaSelection($0, context: context) }.filter { wanted.contains($0.id) }
        }
    }

    private func selections(matching lookup: @escaping @Sendable ([Album], [Playlist], VoicePlaybackContext) -> [VoiceMediaSelection]) async throws -> [VoiceMediaSelection] {
        guard let access = context() else { throw VoicePlaybackError.openApp }
        // First-launch artwork/profile derivation or a scan can replace the snapshot while lookup
        // runs off-main. Resolve again, never return stale matches or reuse an old revision. Keep
        // retries bounded and pinned to the original access, including its transient session/token.
        for attempt in 0..<3 {
            guard !Task.isCancelled else { throw VoicePlaybackError.cancelled }
            guard let snapshot = context(), snapshot.hasSameAccess(as: access) else { throw VoicePlaybackError.changed }
            let content = content()
            let result = await Task.detached(priority: .userInitiated) {
                lookup(content.albums, content.playlists, snapshot)
            }.value
            guard !Task.isCancelled else { throw VoicePlaybackError.cancelled }
            guard let current = context(), current.hasSameAccess(as: access) else { throw VoicePlaybackError.changed }
            if current == snapshot { return result }
            if attempt < 2 { diagnostics("Voice lookup refreshed after library update") }
        }
        throw VoicePlaybackError.changed
    }

    /// Reserve at execution entry, before an adapter awaits identifier resolution.
    public func beginRequest() -> UUID { beginCommand() }

    public func isCurrent(_ selection: VoiceMediaSelection) -> Bool { context() == selection.context }

    public func play(_ selection: VoiceMediaSelection, command reservedCommand: UUID? = nil,
                     shuffle: Bool? = nil, repeatMode: PlayerModel.RepeatMode? = nil) async throws {
        guard context() == selection.context else { throw VoicePlaybackError.changed }
        let command = reservedCommand ?? beginCommand()
        guard command == currentCommand() else { throw VoicePlaybackError.cancelled }
        let initial = content()
        let match = await Task.detached(priority: .userInitiated) {
            VoiceMediaResolver.all(albums: initial.albums, playlists: initial.playlists).first { $0.id == selection.matchID }
        }.value
        guard !Task.isCancelled, command == currentCommand() else { throw VoicePlaybackError.cancelled }
        guard context() == selection.context else { throw VoicePlaybackError.changed }
        guard let match else {
            throw VoicePlaybackError.noMatch
        }
        if !isConnected(), !match.tracks.allSatisfy(isDownloaded) { await waitForConnection() }
        guard !Task.isCancelled, command == currentCommand() else { throw VoicePlaybackError.cancelled }
        guard context() == selection.context else { throw VoicePlaybackError.changed }
        let latest = content()
        let current = await Task.detached(priority: .userInitiated) {
            VoiceMediaResolver.all(albums: latest.albums, playlists: latest.playlists).first { $0.id == selection.matchID }
        }.value
        guard !Task.isCancelled, command == currentCommand() else { throw VoicePlaybackError.cancelled }
        guard context() == selection.context else { throw VoicePlaybackError.changed }
        guard let current, current.tracks.map(\.id) == match.tracks.map(\.id) else { throw VoicePlaybackError.changed }
        guard isConnected() || current.tracks.allSatisfy(isDownloaded) else { throw VoicePlaybackError.offline }
        guard play(current.tracks, current.title, shuffle, repeatMode) else { throw VoicePlaybackError.playbackFailed }
    }
}

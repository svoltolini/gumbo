import CryptoKit
import Foundation
import Observation
import GumboShared
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Keeps the Home Screen widgets fed: watches the models, builds a snapshot of what is playing and
/// what is recent, kept and listed, copies the covers it needs into the shared container, and asks
/// WidgetKit to redraw. It watches the models directly rather than a screen, so a play started from
/// a widget while the app sits in the background updates the widgets too.
public final class WidgetFeed {
    /// Everything the widgets show. Reading it inside observation tracking registers the properties;
    /// a change that leaves it equal, such as download progress or queue bookkeeping, is ignored.
    public struct Signature: Equatable {
        public let nowPlayingID: String?
        public let trackTitle: String?
        public let isPlaying: Bool
        public let recentlyPlayed: [String]
        public let recentlyAdded: [String]
        public let coverKeys: [String?]
        public let artworkRevision: UInt64
        public let contentRevision: Int
        public let downloadOwners: [String]
        public let downloadedSongs: Int
        public let playlists: [String]

        public init(library: LibraryStore, player: PlayerModel, downloads: DownloadManager) {
            nowPlayingID = player.album?.id
            trackTitle = player.track?.title
            // The widget's Play/Pause toggles the request; buffering and seeks must not flip it or reload widgets.
            isPlaying = player.isPlaybackRequested
            let played = Array(library.recentlyPlayed.prefix(8))
            let added = Array(library.recentlyAdded.prefix(8))
            recentlyPlayed = played.map(\.id)
            recentlyAdded = added.map(\.id)
            coverKeys = ([player.album].compactMap { $0 } + played + added).map { WidgetFeed.coverKey(for: $0, in: library) }
            artworkRevision = library.artworkRevision
            // Rediscover and the downloads shelf read the whole library, so any published change counts.
            contentRevision = library.contentRevision
            downloadOwners = downloads.listedOwnerIDs.sorted() + [downloads.activeProfileID]
            downloadedSongs = downloads.records.count
            playlists = ([library.favouritesPlaylist, library.favouritesMixPlaylist, library.recentlyPlayedPlaylist] + library.playlists).map { $0.id + $0.name + $0.summary }
        }
    }

    private var library: LibraryStore?
    private var player: PlayerModel?
    private var downloads: DownloadManager?
    private var profiles: ProfileStore?
    private var pending: Task<Void, Never>?
    /// What was last observed, so a change the widgets don't show does not rebuild the snapshot.
    private var observed: (signature: Signature, sessionID: UUID?)?
    /// The last snapshot written for the current authorization, without its timestamp. Writing the
    /// same content again would only spend WidgetKit's reload budget.
    private var lastWritten: Data?
    /// Rediscover's daily order of the whole library, kept until the library or the day changes.
    private var rediscoverOrder: (revision: Int, day: String, albums: [Album])?

    public init() {
        // A saved widget is not evidence that the profile opened in this app launch.
        WidgetStore.resetAuthorization()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    public func start(library: LibraryStore, player: PlayerModel, downloads: DownloadManager, profiles: ProfileStore) {
        self.library = library
        self.player = player
        self.downloads = downloads
        self.profiles = profiles
        observe()
        refresh()
    }

    private func observe() {
        guard let library, let player, let downloads, let profiles else { return }
        let current = withObservationTracking {
            (signature: Signature(library: library, player: player, downloads: downloads), sessionID: profiles.sessionID)
        } onChange: { [weak self] in
            // Fires before the change lands; the hop lets it finish before anything is read.
            Task { @MainActor in
                guard let self else { return }
                let previous = self.observed
                self.observe()
                if let previous, let now = self.observed, previous.signature == now.signature, previous.sessionID == now.sessionID { return }
                self.refresh()
            }
        }
        observed = current
    }

    /// Writes a fresh snapshot shortly after being called; repeated calls within the delay coalesce,
    /// and so does the work of building it.
    public func refresh() {
        pending?.cancel()
        guard let library, let player, let downloads, let profiles else { return }
        let sessionID = profiles.sessionID
        let changed = WidgetStore.setSession(sessionID)
        if changed {
            lastWritten = nil
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
        guard let sessionID, let publication = WidgetStore.publication(for: sessionID) else { return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, profiles.sessionID == sessionID else { return }
            // Checking the downloaded files stats each of them, so it runs off the main actor.
            let check = downloads.widgetDownloadCheck()
            let newest = library.recentlyAdded
            let tracks = library.tracks
            let (keptAlbums, songCount) = await Task.detached(priority: .utility) {
                (Array(check.verifiedAlbums(newest).prefix(12)), check.verifiedSongCount(tracks))
            }.value
            guard !Task.isCancelled, profiles.sessionID == sessionID else { return }
            await publish(library: library, player: player, kept: keptAlbums, downloadedSongCount: songCount, publication: publication)
        }
    }

    private func publish(library: LibraryStore, player: PlayerModel, kept: [Album], downloadedSongCount: Int, publication: WidgetStore.Publication) async {
        var sources: [String: URL] = [:]
        var heroKeys: Set<String> = []
        func describe(_ album: Album) -> WidgetSnapshot.Album {
            let key = Self.coverKey(for: album, in: library)
            if let key, let url = library.coverURL(for: album) { sources[key] = url }
            return WidgetSnapshot.Album(
                id: album.id, title: album.title, artist: album.artist, colorA: album.colorA, colorB: album.colorB,
                year: album.year > 0 ? album.year : nil, genre: album.genre == "Unknown genre" ? nil : album.genre, coverKey: key
            )
        }
        func describe(_ playlist: Playlist) -> WidgetSnapshot.PlaylistInfo {
            let kind: WidgetSnapshot.PlaylistInfo.Kind = switch playlist.id {
            case Playlist.favouritesID: .favourites
            case Playlist.favouritesMixID: .mix
            case Playlist.recentlyPlayedID: .recentlyPlayed
            case Playlist.libraryShuffleID: .shuffle
            default: .local
            }
            return WidgetSnapshot.PlaylistInfo(id: playlist.id, name: playlist.name, summary: playlist.summary, kind: kind, covers: playlist.covers.prefix(4).map(describe))
        }

        let lead = player.album
        let played = Array(library.recentlyPlayed.prefix(8))
        let added = Array(library.recentlyAdded.prefix(8))
        let playlists = [library.favouritesPlaylist, library.favouritesMixPlaylist, library.recentlyPlayedPlaylist, library.libraryShufflePlaylist] + library.playlists.prefix(8)
        // Albums not played lately, in an order that stays put for the day and changes overnight.
        let recent = Set(played.map(\.id) + [lead?.id].compactMap { $0 })
        let rediscover = Array(dailyOrder(of: library).lazy.filter { !recent.contains($0.id) }.prefix(24))

        var snapshot = WidgetSnapshot(
            nowPlaying: lead.map(describe),
            trackTitle: player.track?.title,
            isPlaying: player.isPlaybackRequested,
            recentlyPlayed: played.map(describe),
            recentlyAdded: added.map(describe),
            downloads: kept.map(describe),
            downloadedSongCount: downloadedSongCount,
            playlists: playlists.map(describe),
            rediscover: rediscover.map(describe)
        )
        // Lead albums get the big copy: the small widgets fill their whole face with them.
        for album in [lead, played.first, added.first, kept.first].compactMap({ $0 }) + rediscover {
            if let key = Self.coverKey(for: album, in: library) { heroKeys.insert(key) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let content = try? encoder.encode(snapshot)
        if let content, content == lastWritten { return }
        snapshot.updated = .now
        let published = await WidgetStore.write(snapshot, publication: publication, coverSources: sources, heroKeys: heroKeys)
        guard published else { return }
        lastWritten = content
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Every album in the day's Rediscover order, with each hash worked out once per album.
    private func dailyOrder(of library: LibraryStore) -> [Album] {
        let day = DailySeed.dayKey()
        if let cached = rediscoverOrder, cached.revision == library.contentRevision, cached.day == day { return cached.albums }
        let albums = library.albums
            .map { (key: DailySeed.stableHash($0.id + day), album: $0) }
            .sorted { $0.key < $1.key }
            .map(\.album)
        rediscoverOrder = (library.contentRevision, day, albums)
        return albums
    }

    /// File stem for an album's cover copies, changing when the cover itself is replaced.
    public static func coverKey(for album: Album, in library: LibraryStore) -> String? {
        guard let url = library.coverURL(for: album) else { return nil }
        let digest = SHA256.hash(data: Data((url.absoluteString + "|" + album.id).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(digest)-v\(library.coverVersion(for: album))"
    }
}

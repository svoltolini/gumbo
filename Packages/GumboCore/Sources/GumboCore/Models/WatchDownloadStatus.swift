import Foundation

/// What a Watch playlist's download row and detail screen show.
public nonisolated enum WatchDownloadStatus: Equatable, Sendable {
    case none
    case downloading(done: Int, total: Int)
    case downloaded
    /// Some songs are saved and play offline; the rest can still be downloaded.
    case partial(available: Int, total: Int, message: String?)
    case failed(String)

    /// `validated` holds the saved songs that pass their checks for the current playlist;
    /// `pending` the songs still being transferred.
    public static func resolve(trackIDs: Set<String>, manifest: WatchDownloadManifest?, validated: Set<String>,
                               pending: Set<String>?, error: String?) -> Self {
        guard let manifest else { return .none }
        let total = trackIDs.count
        let done = validated.intersection(trackIDs).count
        if total > 0, done == total { return .downloaded }
        if let pending, !pending.isEmpty { return .downloading(done: done, total: total) }
        if done > 0 { return .partial(available: done, total: total, message: error) }
        if let error { return .failed(error) }
        if manifest.hasStoredFiles, !manifest.desired.subtracting(validated).isEmpty {
            return .failed("Download again to finish.")
        }
        return .none
    }
}

/// Saved-file checks open each file, so the Watch remembers their results between syncs.
/// Owners forget a path whenever they write it, and clear everything when files may have
/// changed on disk (a catalogue sync, a removal or a server deletion).
public nonisolated struct WatchFileValidationCache: Sendable {
    private struct Key: Hashable, Sendable {
        var path: String
        var expectedBytes: Int64?
    }

    private var results: [Key: Bool] = [:]

    public init() {}

    public mutating func isValid(_ url: URL, expectedBytes: Int64?,
                                 check: (URL, Int64?) -> Bool = WatchDownloadManifest.isValidFile) -> Bool {
        let key = Key(path: url.standardizedFileURL.path, expectedBytes: expectedBytes)
        if let known = results[key] { return known }
        let valid = check(url, expectedBytes)
        results[key] = valid
        return valid
    }

    public mutating func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        results = results.filter { $0.key.path != path }
    }

    public mutating func removeAll() { results.removeAll() }
}

nonisolated extension WatchPlaylist {
    /// For each song row, its position among the saved files handed to the player, or nil when
    /// that occurrence is not on the Watch. `available` is a subsequence of `tracks` in order.
    public func playbackPositions(available: [WatchTrack]) -> [Int?] {
        var next = 0
        return tracks.map { track in
            guard next < available.count, available[next] == track else { return nil }
            defer { next += 1 }
            return next
        }
    }
}

nonisolated extension WatchCatalogue {
    /// A transfer counts only while it still matches this catalogue's copy of its song; one for
    /// a song that left the playlist or changed on the server must not complete or fail it.
    public func isCurrent(_ job: WatchDownloadJob) -> Bool {
        guard let playlist = playlists.first(where: { $0.cacheID == job.playlistKey }),
              let track = playlist.tracks.first(where: { $0.id == job.trackID }) else { return false }
        return WatchDownloadJob(playlist: playlist, track: track, generation: job.generation) == job
    }
}

/// How a running download follows a playlist edit without starting over: transfers for songs
/// that stayed the same continue, and songs that joined are requested under the same generation.
/// A changed song keeps its saved file name, so its old transfer could overwrite a new one in
/// this generation; it is left, like songs that failed earlier, for the next Download.
public nonisolated struct WatchDownloadRetarget: Equatable, Sendable {
    /// Songs whose in-flight transfer still matches the playlist.
    public var kept: Set<String>
    /// Songs to request now, in playlist order.
    public var added: [WatchTrack]

    public init(previous: WatchPlaylist?, current: WatchPlaylist, pending: Set<String>, available: Set<String>, generation: UUID) {
        func jobs(_ playlist: WatchPlaylist) -> [String: WatchDownloadJob] {
            Dictionary(playlist.uniqueTracks.compactMap { track in
                WatchDownloadJob(playlist: playlist, track: track, generation: generation).map { (track.id, $0) }
            }, uniquingKeysWith: { first, _ in first })
        }
        let now = jobs(current)
        guard let previous else {
            // Without the earlier membership, a stale transfer is found only when it ends or is cancelled.
            kept = pending.filter { now[$0] != nil }
            added = []
            return
        }
        let before = jobs(previous)
        let kept = pending.filter { now[$0] != nil && before[$0] == now[$0] }
        self.kept = kept
        added = current.uniqueTracks.filter { track in
            now[track.id] != nil && before[track.id] == nil
                && !available.contains(track.id) && !kept.contains(track.id)
        }
    }
}

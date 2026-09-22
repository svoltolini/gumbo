import Foundation
import GumboShared

/// A song as the watch knows it: enough to list it, size it and fetch it from the server.
public nonisolated struct WatchTrack: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var artist: String
    public var album: String
    /// Optional for catalogues sent by older phones. Artwork is shared once per album.
    public var albumID: String?
    public var duration: TimeInterval
    /// Path on the drive, the same one File Station streams from.
    public var path: String
    public var fileSize: Int64
    public var format: String
    public var isLossless: Bool
    public var fileRevision: DownloadFileRevision?

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval, path: String, fileSize: Int64, format: String, isLossless: Bool, albumID: String? = nil, fileRevision: DownloadFileRevision? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumID = albumID
        self.duration = duration
        self.path = path
        self.fileSize = fileSize
        self.format = format
        self.isLossless = isLossless
        self.fileRevision = fileRevision
    }

    public var fileExtension: String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "audio" : ext
    }
}

/// Two hex colours; four of these make a playlist's mosaic on the watch.
public nonisolated struct WatchColourPair: Codable, Hashable, Sendable {
    public var a: String
    public var b: String

    public init(a: String, b: String) {
        self.a = a
        self.b = b
    }
}

/// A playlist cut to the watch's song limit.
public nonisolated struct WatchPlaylist: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var isSmart: Bool
    public var coverColours: [WatchColourPair]
    public var tracks: [WatchTrack]
    /// How many songs the playlist has on the phone; the watch carries at most the limit.
    public var totalSongs: Int
    /// Older phone catalogues have no trustworthy cache scope and must be synced again.
    public var driveID: String?
    public var profileID: String?

    public init(id: String, name: String, isSmart: Bool, coverColours: [WatchColourPair], tracks: [WatchTrack], totalSongs: Int, driveID: String? = nil, profileID: String? = nil) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.coverColours = coverColours
        self.tracks = tracks
        self.totalSongs = totalSongs
        self.driveID = driveID
        self.profileID = profileID
    }

    public var uniqueTracks: [WatchTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    public var totalBytes: Int64 { uniqueTracks.reduce(0) { $0 + $1.fileSize } }
    public var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    public var isCut: Bool { totalSongs > tracks.count }

    public var cacheID: String? {
        guard let driveID, !driveID.isEmpty, let profileID, !profileID.isEmpty else { return nil }
        let owner = DownloadManager.cacheKey(trackID: id, driveID: profileID)
        return DownloadManager.cacheKey(trackID: owner, driveID: driveID)
    }
}

/// Structured task metadata keeps NAS paths as data; no path or delimiter becomes a local filename.
public nonisolated struct WatchDownloadJob: Codable, Equatable, Sendable {
    public let playlistKey: String
    public let trackID: String
    public let fileName: String
    public let generation: UUID
    public let expectedBytes: Int64?
    public let fileRevision: DownloadFileRevision?

    public init?(playlist: WatchPlaylist, track: WatchTrack, generation: UUID) {
        guard let key = playlist.cacheID, let driveID = playlist.driveID else { return nil }
        playlistKey = key
        trackID = track.id
        fileName = DownloadManager.cacheKey(trackID: track.id, driveID: driveID) + "." + DownloadManager.safeExtension(track.fileExtension)
        self.generation = generation
        expectedBytes = track.fileSize > 0 ? track.fileSize : nil
        fileRevision = track.fileRevision
    }

    public var encoded: String? { (try? JSONEncoder().encode(self)).map { $0.base64EncodedString() } }

    public static func decode(_ value: String?) -> WatchDownloadJob? {
        guard let value, let data = Data(base64Encoded: value), let job = try? JSONDecoder().decode(Self.self, from: data),
              job.playlistKey.count == 64, job.playlistKey.allSatisfy({ $0.isHexDigit }),
              !job.fileName.isEmpty, (job.fileName as NSString).lastPathComponent == job.fileName else { return nil }
        return job
    }

    public func destination(in root: URL) -> URL {
        root.appending(path: playlistKey, directoryHint: .isDirectory)
            .appending(path: generation.uuidString, directoryHint: .isDirectory)
            .appending(path: fileName)
    }
}

/// File Station sends original audio bytes. A successful status alone does not prove a usable file.
public nonisolated enum WatchDownloadValidation {
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case serverStatus(Int)
        case missingOrEmpty
        case sizeMismatch
        case serverMessage

        public var errorDescription: String? {
            switch self {
            case .serverStatus(let status): "The server answered \(status). Try downloading again."
            case .missingOrEmpty: "The song could not be saved. Try downloading again."
            case .sizeMismatch: "The song did not match its expected size. Refresh the playlist on your iPhone, then try again."
            case .serverMessage: "The server returned a message instead of audio. Reconnect to your NAS, then try again."
            }
        }
    }

    public static func failure(for url: URL, expectedBytes: Int64?, statusCode: Int = 200, contentType: String? = nil) -> Failure? {
        guard statusCode == 200 else { return .serverStatus(statusCode) }
        // URL resource values can retain a previous size after a retry replaces the same path.
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              values[.type] as? FileAttributeType == .typeRegular,
              let bytes = (values[.size] as? NSNumber)?.int64Value, bytes > 0 else { return .missingOrEmpty }
        let type = contentType?.lowercased() ?? ""
        if type.hasPrefix("text/") || type.contains("json") || type.contains("xml") { return .serverMessage }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missingOrEmpty }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512), !head.isEmpty else { return .missingOrEmpty }
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if text.hasPrefix("{") || text.hasPrefix("[") || text.hasPrefix("<") { return .serverMessage }
        if let expectedBytes, expectedBytes > 0, bytes != expectedBytes { return .sizeMismatch }
        return nil
    }
}

/// Desired songs are persisted separately from available files, so a partial transfer stays partial.
public nonisolated struct WatchDownloadManifest: Codable, Sendable {
    public var files: [String: String] = [:]
    public var fileRevisions: [String: DownloadFileRevision] = [:]
    public var desired: Set<String> = []
    public var generation: UUID?

    public init() {}

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        files = try values.decode([String: String].self, forKey: .files)
        desired = try values.decode(Set<String>.self, forKey: .desired)
        generation = try values.decodeIfPresent(UUID.self, forKey: .generation)
        fileRevisions = try values.decodeIfPresent([String: DownloadFileRevision].self, forKey: .fileRevisions) ?? [:]
    }

    /// Preserve existing offline files on upgrade, then remember the last known catalogue so
    /// subsequent same-size edits are detected. This does not certify old files against the NAS.
    public mutating func adoptFileRevisions(from playlist: WatchPlaylist) {
        for track in playlist.tracks where files[track.id] != nil && fileRevisions[track.id] == nil {
            fileRevisions[track.id] = track.fileRevision
        }
    }

    private func matches(_ track: WatchTrack) -> Bool {
        guard let saved = fileRevisions[track.id], let current = track.fileRevision else { return true }
        return saved.matches(current)
    }

    /// Returns only safe relative paths belonging to confirmed source-scoped deletions.
    /// A playlist edit alone never calls this. Retiring its generation rejects late downloads.
    public mutating func removeServerFiles(deletedCacheKeys: Set<String>, removedTrackIDs: Set<String>) -> (paths: [String], affected: Bool) {
        var paths: [String] = []
        var affected = !desired.isDisjoint(with: removedTrackIDs)
        desired.subtract(removedTrackIDs)
        for (id, path) in files {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
                  deletedCacheKeys.contains((String(parts[1]) as NSString).deletingPathExtension) else { continue }
            paths.append(path)
            files[id] = nil
            fileRevisions[id] = nil
            desired.remove(id)
            affected = true
        }
        if affected { generation = nil }
        return (paths, affected)
    }

    /// Includes partial or invalid saved files so the user can always remove their storage.
    public var hasStoredFiles: Bool { !files.isEmpty }

    public func availableFiles(for playlist: WatchPlaylist, root: URL) -> [(track: WatchTrack, url: URL)] {
        guard let key = playlist.cacheID else { return [] }
        return playlist.tracks.compactMap { track in
            guard let path = files[track.id], matches(track) else { return nil }
            guard validateFilePath(path, trackID: track.id, key: key, root: root, expectedBytes: track.fileSize) else { return nil }
            let url = root.appending(path: key).appending(path: path)
            return (track, url)
        }
    }

    /// Validates a file entry and returns true if the file exists, has correct format, and passes validation.
    private func validateFilePath(_ path: String, trackID: String, key: String, root: URL, expectedBytes: Int64?) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              !parts[1].isEmpty, parts[1] != ".", parts[1] != ".." else { return false }
        let url = root.appending(path: key).appending(path: path)
        return WatchDownloadValidation.failure(for: url, expectedBytes: expectedBytes) == nil
    }

    /// Returns the set of track IDs in `files` that pass validation for the given playlist.
    /// This validates both path format and actual file existence/integrity.
    public func validatedFileIDs(for playlist: WatchPlaylist, root: URL) -> Set<String> {
        guard let key = playlist.cacheID else { return [] }
        let tracksByID = Dictionary(playlist.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(files.keys.filter { trackID in
            guard let path = files[trackID],
                  let track = tracksByID[trackID], matches(track) else { return false }
            return validateFilePath(path, trackID: trackID, key: key, root: root, expectedBytes: track.fileSize)
        })
    }

    /// Returns the set of track IDs that have manifest entries but fail validation (missing/corrupt files).
    /// These entries should be pruned from the manifest to avoid stale state.
    public func invalidFileIDs(for playlist: WatchPlaylist, root: URL) -> Set<String> {
        guard let key = playlist.cacheID else { return [] }
        let tracksByID = Dictionary(playlist.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(files.keys.filter { trackID in
            guard let path = files[trackID] else { return false }
            let track = tracksByID[trackID]
            if let track, !matches(track) { return true }
            return !validateFilePath(path, trackID: trackID, key: key, root: root, expectedBytes: track?.fileSize)
        })
    }

    /// Returns track IDs in `desired` that are not in `files` or whose files fail validation.
    /// These represent incomplete downloads that should be resumed.
    public func outstandingTrackIDs(for playlist: WatchPlaylist, root: URL) -> Set<String> {
        let validated = validatedFileIDs(for: playlist, root: root)
        return desired.subtracting(validated)
    }

    /// Removes invalid file entries and returns the pruned track IDs.
    public mutating func pruneInvalidFiles(for playlist: WatchPlaylist, root: URL) -> Set<String> {
        let invalid = invalidFileIDs(for: playlist, root: root)
        for trackID in invalid {
            files.removeValue(forKey: trackID)
            fileRevisions.removeValue(forKey: trackID)
        }
        return invalid
    }
}

/// Everything the watch shows: the playlists of the phone's active profile, each cut to the limit.
public nonisolated struct WatchCatalogue: Codable, Sendable {
    /// The most songs one playlist brings to the watch, for the watch's sake.
    public static let songLimit = 200

    public var serverName: String
    public var profileName: String?
    public var playlists: [WatchPlaylist]
    public var generatedAt: Date
    /// Small source-library thumbnails, never full-sized cover files or external artwork.
    public var artwork: [String: Data] = [:]
    /// Confirmed NAS deletions, scoped independently of a profile's playlist membership.
    public var serverDeletedTrackIDs: [String: [String]] = [:]
    public var serverSourceID: String?
    public var serverDeletionRevision: UInt64 = 0
    /// Monotonic within one Watch authorization, including snapshots whose only change is artwork.
    public var snapshotRevision: UInt64 = 0
    public private(set) var artworkPolicyVersion: Int

    public init(serverName: String, profileName: String?, playlists: [WatchPlaylist], generatedAt: Date = .now) {
        self.serverName = serverName
        self.profileName = profileName
        self.playlists = playlists
        self.generatedAt = generatedAt
        artworkPolicyVersion = ArtworkPolicy.version
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverName = try values.decode(String.self, forKey: .serverName)
        profileName = try values.decodeIfPresent(String.self, forKey: .profileName)
        playlists = try values.decode([WatchPlaylist].self, forKey: .playlists)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        serverDeletedTrackIDs = try values.decodeIfPresent([String: [String]].self, forKey: .serverDeletedTrackIDs) ?? [:]
        serverSourceID = try values.decodeIfPresent(String.self, forKey: .serverSourceID)
        serverDeletionRevision = try values.decodeIfPresent(UInt64.self, forKey: .serverDeletionRevision) ?? 0
        snapshotRevision = try values.decodeIfPresent(UInt64.self, forKey: .snapshotRevision) ?? 0
        let storedPolicy = try? values.decode(Int.self, forKey: .artworkPolicyVersion)
        if storedPolicy == ArtworkPolicy.version {
            artwork = WatchArtwork.bounded(try values.decodeIfPresent([String: Data].self, forKey: .artwork) ?? [:],
                                           albumIDs: Set(playlists.flatMap(\.tracks).compactMap(\.albumID)))
        }
        if storedPolicy != ArtworkPolicy.version {
            // Apply this to every decode, including queued messages from an older phone.
            // Playlist/track identities and download ownership remain unchanged.
            for index in playlists.indices {
                let id = playlists[index].id
                playlists[index].coverColours = playlists[index].coverColours.indices.map { offset in
                    let colours = ArtPalette.pair(for: "watch-\(id)-\(offset)")
                    return WatchColourPair(a: colours.0, b: colours.1)
                }
            }
        }
        artworkPolicyVersion = ArtworkPolicy.version
    }

    public var deletedCacheKeys: Set<String> {
        Set(serverDeletedTrackIDs.flatMap { source, ids in
            ids.map { DownloadManager.cacheKey(trackID: $0, driveID: source) }
        })
    }

    /// Filter even a queued/stale playlist snapshot while its derived UI rows catch up.
    public mutating func applyServerDeletions(_ deletions: [String: [String]]) {
        serverDeletedTrackIDs = deletions
        for index in playlists.indices {
            guard let source = playlists[index].driveID, let removed = deletions[source] else { continue }
            let ids = Set(removed)
            let before = playlists[index].tracks.count
            playlists[index].tracks.removeAll { ids.contains($0.id) }
            playlists[index].totalSongs = max(playlists[index].tracks.count, playlists[index].totalSongs - before + playlists[index].tracks.count)
        }
        artwork = WatchArtwork.bounded(artwork, albumIDs: Set(playlists.flatMap(\.tracks).compactMap(\.albumID)))
    }

    /// The same catalogue with the timestamp removed, so two builds of the same content compare equal.
    public var contentKey: Data? {
        var copy = self
        copy.generatedAt = .distantPast
        copy.snapshotRevision = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(copy)
    }

    /// Compare only after matching authorization; a new authorization clears the previous snapshot.
    /// Revision zero preserves old-phone compatibility until a newer phone has sent an ordered snapshot.
    public func isAtLeastAsRecent(as previous: WatchCatalogue) -> Bool {
        snapshotRevision >= previous.snapshotRevision && serverDeletionRevision >= previous.serverDeletionRevision
    }

    /// Navigation values are snapshots; resolve them against this catalogue before taking action.
    public func playlist(matching snapshot: WatchPlaylist) -> WatchPlaylist? {
        playlists.first {
            $0.id == snapshot.id && $0.cacheID == snapshot.cacheID
                && $0.driveID == snapshot.driveID && $0.profileID == snapshot.profileID
        }
    }
}

/// What the watch needs to reach the server by itself.
public nonisolated struct WatchCredentials: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var account: String
    public var password: String
    public var driveID: String?
    /// Absent in the original DSM-only protocol. Unknown versions must never fall back to DSM.
    public var protocolVersion: Int?
    public var provider: ProviderConfiguration?

    public init(baseURL: URL, account: String, password: String, driveID: String? = nil, provider: ProviderConfiguration? = nil) {
        self.baseURL = baseURL
        self.account = account
        self.password = password
        self.driveID = driveID
        self.provider = provider
        protocolVersion = provider == nil ? nil : 2
    }

    public var providerKind: NASProviderKind? {
        if protocolVersion == nil, provider == nil { return .synology }
        guard protocolVersion == 2, let provider, provider.endpoint == baseURL else { return nil }
        return provider.kind
    }

    /// SMB is a phone relay descriptor: account names and secrets must not cross to Watch.
    public var isUsable: Bool {
        guard let driveID, !driveID.isEmpty, let kind = providerKind else { return false }
        switch kind {
        case .smb: return account.isEmpty && password.isEmpty
        case .webDAV:
            return !account.isEmpty && !password.isEmpty && provider?.sourceID(account: account) == driveID
        case .synology: return !account.isEmpty && !password.isEmpty && NASOrigin(url: baseURL) != nil
        }
    }

    public func matches(_ playlist: WatchPlaylist) -> Bool {
        guard isUsable, let driveID else { return false }
        return driveID == playlist.driveID
    }

    public func permitsWebDAVDownload(original: URL?, current: URL?) -> Bool {
        guard isUsable, providerKind == .webDAV, let original, original == current,
              let scope = try? WebDAVPathScope(baseURL: baseURL),
              (try? scope.path(for: original.absoluteString, relativeTo: baseURL)) != nil else { return false }
        return true
    }
}

/// The phone resolves membership and paths from its own current catalogue, never from request paths.
public nonisolated struct WatchAudioRelayRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let playlistID: String
    public let job: WatchDownloadJob

    public init(playlist: WatchPlaylist, job: WatchDownloadJob) {
        version = 2
        playlistID = playlist.id
        self.job = job
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data?) -> Self? {
        guard let data, data.count <= 16_384, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 2, WatchDownloadJob.decode(value.job.encoded) == value.job else { return nil }
        return value
    }

    public func resolve(in catalogue: WatchCatalogue) -> (playlist: WatchPlaylist, track: WatchTrack)? {
        guard version == 2,
              let playlist = catalogue.playlists.first(where: { $0.id == playlistID && $0.cacheID == job.playlistKey }),
              let track = playlist.tracks.first(where: { $0.id == job.trackID }),
              WatchDownloadJob(playlist: playlist, track: track, generation: job.generation) == job,
              !catalogue.deletedCacheKeys.contains((job.fileName as NSString).deletingPathExtension) else { return nil }
        return (playlist, track)
    }

    public func isCurrent(in catalogue: WatchCatalogue, manifest: WatchDownloadManifest?) -> Bool {
        resolve(in: catalogue) != nil && manifest?.generation == job.generation && manifest?.desired.contains(job.trackID) == true
    }
}

extension LibraryStore {
    /// Every playlist with songs, smart ones first, each cut to the watch's limit. Songs the
    /// server cannot serve (no path) are left out, and so is the library shuffle, which changes
    /// on every reading and would keep the watch downloading.
    public func watchCatalogue(serverName: String, profileName: String?) -> WatchCatalogue {
        let all = [favouritesPlaylist, favouritesMixPlaylist, recentlyPlayedPlaylist] + playlists
        let converted: [WatchPlaylist] = all.compactMap { playlist in
            let tracks: [WatchTrack] = playlist.tracks.prefix(WatchCatalogue.songLimit).compactMap { track in
                guard let path = track.path else { return nil }
                let album = album(id: track.albumID)
                return WatchTrack(
                    id: track.id, title: track.title, artist: track.artist ?? album?.artist ?? "",
                    album: album?.title ?? "", duration: track.duration, path: path,
                    fileSize: track.fileSize ?? 0, format: track.format, isLossless: track.isLossless, albumID: track.albumID,
                    fileRevision: DownloadFileRevision(track: track)
                )
            }
            guard !tracks.isEmpty else { return nil }
            return WatchPlaylist(
                id: playlist.id, name: playlist.name, isSmart: playlist.kind == .smart,
                coverColours: playlist.covers.prefix(4).map { WatchColourPair(a: $0.colorA, b: $0.colorB) },
                tracks: tracks, totalSongs: playlist.tracks.count,
                driveID: catalogue.driveID, profileID: profiles?.active?.id ?? profiles?.lastActiveID
            )
        }
        var result = WatchCatalogue(serverName: serverName, profileName: profileName, playlists: converted)
        result.serverSourceID = catalogue.driveID
        return result
    }

    /// Snapshot local NAS-derived covers on the main actor; decoding happens off the UI actor.
    public func watchArtworkSources(for snapshot: WatchCatalogue) -> [WatchArtworkSource] {
        guard snapshot.serverSourceID == catalogue.driveID else { return [] }
        var seen = Set<String>()
        var sources: [WatchArtworkSource] = []
        for playlist in snapshot.playlists {
            for track in playlist.tracks {
                guard let id = track.albumID, seen.insert(id).inserted,
                      let album = album(id: id), let url = coverURL(for: album) else { continue }
                sources.append(WatchArtworkSource(albumID: id, url: url, version: coverVersion(for: album)))
                if sources.count == WatchArtwork.albumLimit { return sources }
            }
        }
        return sources
    }
}

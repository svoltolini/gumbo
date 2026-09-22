import Foundation

/// The catalogue's known file identity when a download was requested. This is a freshness
/// check, not a content hash or an authorization grant. Presentation-only regrouping is excluded.
public nonisolated struct DownloadFileRevision: Codable, Hashable, Sendable {
    public let path: String?
    public let size: Int64?
    public let modifiedAt: TimeInterval?
    public let version: String?
    private let tags: Tags?

    private struct Tags: Codable, Hashable, Sendable {
        let album: String?
        let albumArtist: String?
        let genre: String?
    }

    public init(track: Track) {
        path = track.path
        size = track.fileSize.flatMap { $0 > 0 ? $0 : nil }
        modifiedAt = track.sourceModifiedAt.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        version = track.sourceVersion.flatMap { $0.isEmpty ? nil : $0 }
        tags = track.isEnriched ? Tags(album: track.albumTitleTag, albumArtist: track.albumArtistTag, genre: track.genreTag) : nil
    }

    /// Missing evidence in an older catalogue does not prove that a file changed. Compare every
    /// fact known on both sides, including embedded tags when both snapshots were enriched.
    public func matches(_ current: Self) -> Bool {
        if let path, let other = current.path, path != other { return false }
        if let size, let other = current.size, size != other { return false }
        if let modifiedAt, let other = current.modifiedAt, modifiedAt != other { return false }
        if let version, let other = current.version, version != other { return false }
        if let tags, let other = current.tags, tags != other { return false }
        return true
    }
}

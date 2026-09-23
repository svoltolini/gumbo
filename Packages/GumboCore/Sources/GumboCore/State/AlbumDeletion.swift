import Foundation

/// A read-only review of one album's exact files. Only LibraryStore can prepare a usable request.
public nonisolated struct AlbumDeletionRequest: Identifiable, Sendable {
    public let id: UUID
    public let albumTitle: String
    public let tracks: [Track]
    public var fileCount: Int { tracks.count }
    let albumID: String
    let sourceID: String
    let rootPath: String
    let profileSession: UUID
    let connectionToken: UUID
    let catalogueRevision: Int
    let entries: [String: RemoteEntry]
    var helper: TagServiceConfiguration? = nil
}

public nonisolated struct AlbumDeletionProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let title: String
}

public nonisolated struct AlbumDeletionReport: Sendable {
    public var deleted: [Track] = []
    public var failures: [MetadataWriteFailure] = []
    public var wasCancelled = false
    /// Files without a confirmed deletion, including unattempted files and uncertain network failures.
    public var remainingCount = 0
    /// A NAS deletion can succeed even if saving the updated local cache fails.
    public var persistenceError: String?
    public init() {}
}

public nonisolated enum AlbumDeletionError: LocalizedError, Sendable {
    case notAuthorized, unavailable, busy, changed, unsafePath, unverifiedFile

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: "Open the library owner's profile to delete an album from the NAS."
        case .unavailable: "Connect to your music server and finish syncing before deleting an album."
        case .busy: "Wait for the current scan or file changes to finish, then try again."
        case .changed: "The album or connection changed. Close this review and open it again before deleting."
        case .unsafePath: "This album contains a file Gumbo could not safely identify. Refresh your library and try again."
        case .unverifiedFile: "A file could not be verified on the NAS. Refresh your library and try again."
        }
    }
}

nonisolated enum AlbumDeletionPaths {
    static func isSong(_ path: String, inside root: String) -> Bool {
        guard path.hasPrefix("/"), root.hasPrefix("/"), !path.contains("\0"), !root.contains("\0"),
              !path.hasSuffix("/"), !path.contains("//"), !root.contains("//") else { return false }
        let parts = path.split(separator: "/")
        let rootParts = root.split(separator: "/")
        guard !parts.contains("."), !parts.contains(".."), !rootParts.contains("."), !rootParts.contains(".."),
              parts.count > rootParts.count, parts.starts(with: rootParts) else { return false }
        // A catalogue saved before hidden files were ignored can still list "._01 - Song.flac". It is
        // not a song: never rewrite, review or delete it, and never count it with an album's files.
        guard let name = parts.last, !RemoteDriveSupport.isHidden(String(name)) else { return false }
        return RemoteDriveSupport.audioExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

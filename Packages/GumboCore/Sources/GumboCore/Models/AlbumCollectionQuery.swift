import Foundation

/// Navigation stores the selection rule, so a scan or tag edit updates both rows and membership.
public nonisolated enum AlbumCollectionQuery: Hashable, Sendable {
    case genre(String), decade(String), recentlyAdded, recentlyPlayed, highResolution
}

extension LibraryStore {
    public func albums(matching query: AlbumCollectionQuery) -> [Album] {
        switch query {
        case .genre(let name): genres.first { $0.name == name }?.albums ?? []
        case .decade(let label): decades.first { $0.label == label }?.albums ?? []
        case .recentlyAdded: recentlyAdded
        case .recentlyPlayed: recentlyPlayed
        case .highResolution: hiResAlbums
        }
    }
}

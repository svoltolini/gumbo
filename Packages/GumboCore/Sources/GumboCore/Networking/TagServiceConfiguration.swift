import CryptoKit
import Foundation

/// Explicit mapping from this library folder to the helper's mounted root. The bearer token is
/// separate from the music-server password and stays in this device's Keychain.
public nonisolated struct TagServiceConfiguration: Codable, Hashable, Sendable {
    public let endpoint: URL
    public let sourceID: String
    public let libraryRoot: String
    /// Missing on existing installations: deletion is always an explicit opt-in.
    public let allowsReviewedDeletion: Bool?

    public init(endpoint: URL, sourceID: String, libraryRoot: String, allowsReviewedDeletion: Bool = false) {
        self.endpoint = endpoint; self.sourceID = sourceID; self.libraryRoot = libraryRoot
        self.allowsReviewedDeletion = allowsReviewedDeletion
    }

    public var keychainAccount: String {
        let framed = try! JSONEncoder().encode([endpoint.absoluteString, sourceID, libraryRoot])
        return "metadata-helper-v1:" + SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined()
    }

    public func relativePath(_ path: String) throws -> String {
        guard libraryRoot.hasPrefix("/"), path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            throw RemoteTagService.Error.invalidPath
        }
        let root = libraryRoot == "/" ? "/" : libraryRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = root == "/" ? "/" : "/" + root + "/"
        guard path.hasPrefix(prefix) else { throw RemoteTagService.Error.invalidPath }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw RemoteTagService.Error.invalidPath
        }
        return relative
    }

    public func client() throws -> RemoteTagService {
        guard let token = KeychainStore.password(for: keychainAccount) else { throw RemoteTagService.Error.invalidToken }
        return try RemoteTagService(endpoint: endpoint, token: token)
    }
}

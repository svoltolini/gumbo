import CryptoKit
import Foundation

/// A verified connection's namespace. Routes and accounts are not assumed to be interchangeable.
public nonisolated enum NASSource {
    public static func identifier(baseURL: URL, account: String) -> String {
        let origin = NASOrigin(url: baseURL)?.identifier ?? "invalid-origin"
        let encoded = (try? JSONEncoder().encode([origin, account])) ?? Data()
        return "nas-v2-" + SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}

/// Passwords remain in Keychain. This record carries only their verified source and recovery state.
nonisolated struct FamilyAccessRecord: Codable, Equatable {
    var account: String
    var sourceID: String
    var pendingRevocationScope: String?
    /// New for every password saved on this device, so iCloud sync can tell a local change from
    /// another device's copy. Nil for records saved before it existed.
    var revision: String? = nil

    var keychainAccount: String { "family-v2|" + sourceID + "|" + account }
}

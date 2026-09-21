import Foundation
import Security

/// The person's optional NAS password in iCloud Keychain, separate from local remembered
/// passwords and the credentials they explicitly share with their family. Saving here requires
/// an explicit opt-in in the app; a successful save does not mean another device has received it.
public nonisolated enum SyncedServerCredentialStore {
    public static var isSupported: Bool {
        #if os(iOS) || os(macOS)
        true
        #else
        false
        #endif
    }

    /// The same app-ID access group is provisioned for the iOS and macOS apps only. Reading the
    /// build-expanded value avoids assuming that a team's ID always equals its App ID prefix.
    private static var store: SyncedServerCredentialKeychain {
        SyncedServerCredentialKeychain(
            accessGroup: Bundle.main.object(forInfoDictionaryKey: "GumboKeychainAccessGroup") as? String,
            isSupported: isSupported,
            operations: .live
        )
    }

    @discardableResult
    public static func save(password: String, for connection: ServerConnection) -> Bool {
        store.save(password: password, for: connection)
    }

    public static func password(for connection: ServerConnection) -> String? {
        store.password(for: connection)
    }

    /// Removing a synchronized item removes that copy from the person's other devices too.
    /// Device-local remembered passwords are deliberately left alone.
    @discardableResult
    public static func delete(for connection: ServerConnection) -> Bool {
        store.delete(for: connection)
    }
}

/// The Security boundary is injectable so contract tests never access a real Keychain.
nonisolated struct SyncedCredentialKeychainOperations: Sendable {
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var add: @Sendable ([String: Any]) -> OSStatus
    var copy: @Sendable ([String: Any]) -> (OSStatus, Data?)
    var delete: @Sendable ([String: Any]) -> OSStatus

    static let live = Self(
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        copy: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

nonisolated struct SyncedServerCredentialKeychain: Sendable {
    private static let service = "com.samuelvoltolini.gumbo.personal-server-sync.v1"
    let accessGroup: String?
    let isSupported: Bool
    let operations: SyncedCredentialKeychainOperations

    private func query(for connection: ServerConnection) -> [String: Any]? {
        guard isSupported,
              let accessGroup, !accessGroup.isEmpty, !accessGroup.contains("$("),
              !connection.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = credentialKey(for: connection) else { return nil }
        // A structured encoding avoids delimiter collisions and keeps the account's case intact.
        // URL paths, display names and music folders are not authentication boundaries.
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.base64EncodedString(),
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func credentialKey(for connection: ServerConnection) -> Data? {
        if connection.providerKind == .synology {
            guard let origin = NASOrigin(url: connection.baseURL) else { return nil }
            // Preserve the exact existing iCloud Keychain account for DSM users.
            return try? JSONEncoder().encode([origin.identifier, connection.account])
        }
        guard connection.provider != nil else { return nil }
        return try? JSONEncoder().encode(["provider-v1", connection.sourceID, connection.account])
    }

    func save(password: String, for connection: ServerConnection) -> Bool {
        guard !password.isEmpty, let query = query(for: connection) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = operations.update(query, attributes)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        let inserted = operations.add(query.merging(attributes) { _, new in new })
        if inserted == errSecSuccess { return true }
        // Another request (or sync delivery) can insert between update and add. Never delete an
        // existing password as an upsert strategy: a failed add would otherwise lose the secret.
        guard inserted == errSecDuplicateItem else { return false }
        return operations.update(query, attributes) == errSecSuccess
    }

    func password(for connection: ServerConnection) -> String? {
        guard var query = query(for: connection) else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.copy(query)
        guard status == errSecSuccess, let data,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        return password
    }

    func delete(for connection: ServerConnection) -> Bool {
        guard let query = query(for: connection) else { return false }
        let status = operations.delete(query)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

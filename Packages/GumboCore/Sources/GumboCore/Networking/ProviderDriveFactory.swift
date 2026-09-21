import Foundation

public nonisolated enum ProviderDriveFactory {
    /// Validates a new session before it can replace the last usable library.
    public static func open(_ connection: ServerConnection, password: String) async throws -> any RemoteDrive {
        guard let configuration = connection.provider, configuration.kind != .synology else { throw ProviderError.invalidConfiguration }
        switch configuration.kind {
        case .webDAV:
            let drive = try WebDAVDrive(baseURL: configuration.endpoint, username: connection.account, password: password, sourceID: connection.sourceID)
            _ = try await drive.roots()
            return drive
        case .smb:
            let account = configuration.domain.map { $0 + "\\" + connection.account } ?? connection.account
            let drive = try SMBDrive(endpoint: configuration.endpoint, share: configuration.share ?? "", account: account,
                                     password: password, sourceID: connection.sourceID, displayName: connection.name,
                                     security: configuration.requiresEncryption ? .encrypted : .signed)
            try await drive.connect()
            return drive
        case .synology:
            throw ProviderError.invalidConfiguration
        }
    }
}

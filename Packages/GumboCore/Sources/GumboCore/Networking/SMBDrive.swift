import Foundation

/// Both modes authenticate every file operation. Encryption requires SMB3; signed mode supports SMB2/3.
public nonisolated enum SMBSecurityPolicy: String, Codable, Sendable {
    case encrypted
    case signed
}

public nonisolated enum SMBDriveError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint, invalidShare, invalidPath, credentialsRequired, authenticationRequired, unavailableOnPlatform
    case missingPath, permissionDenied, fileBusy, disconnected, timedOut, invalidResponse, securityPolicy, io(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter an SMB server address without a username, password, share, query or fragment."
        case .invalidShare: "Choose a valid shared folder on this server."
        case .invalidPath: "This file path is outside the selected shared folder."
        case .credentialsRequired: "Enter a personal server account and password. Guest access is not supported."
        case .authenticationRequired: "The server could not sign you in. Check your account and password, and make sure the account is active."
        case .unavailableOnPlatform: "This device receives SMB music through your iPhone."
        case .missingPath: "This file or folder is no longer on the server."
        case .permissionDenied: "Your server account cannot open this file or folder."
        case .fileBusy: "Another app is using this file. Let it finish, then try again."
        case .disconnected: "The connection to the shared folder was interrupted. Try again."
        case .timedOut: "The server took too long to respond. Try again."
        case .invalidResponse: "The server returned an incomplete or invalid file response."
        case .securityPolicy: "The server does not support the secure SMB connection you selected."
        case .io: "The shared folder could not complete this request. Try again."
        }
    }
}

nonisolated extension SMBDriveError {
    /// Only used for a failed connection/login, before a context is retained for file operations.
    /// Keep file/share ACCESS_DENIED separate: changing a password cannot grant folder permissions.
    static func authenticationFailure(for status: UInt32) -> SMBDriveError? {
        switch status {
        case 0xC0000064, // STATUS_NO_SUCH_USER
             0xC000006A, // STATUS_WRONG_PASSWORD
             0xC000006D, // STATUS_LOGON_FAILURE
             0xC0000071, // STATUS_PASSWORD_EXPIRED
             0xC0000072, // STATUS_ACCOUNT_DISABLED
             0xC0000193, // STATUS_ACCOUNT_EXPIRED
             0xC0000224, // STATUS_PASSWORD_MUST_CHANGE
             0xC0000234: // STATUS_ACCOUNT_LOCKED_OUT
            .authenticationRequired
        default:
            nil
        }
    }
}

/// Validated settings contain no secret and can safely be retained beside the catalogue identity.
nonisolated struct SMBConnectionSettings: Sendable, Equatable {
    let endpoint: URL
    let server: String
    let share: String
    let user: String
    let domain: String
    let security: SMBSecurityPolicy

    init(endpoint: URL, share: String, account: String, security: SMBSecurityPolicy) throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "smb", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              !host.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw SMBDriveError.invalidEndpoint }
        guard Self.validComponent(share), share != ".", share != ".." else { throw SMBDriveError.invalidShare }
        let pieces = account.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: false)
        let user = String(pieces.last ?? "")
        let domain = pieces.count == 2 ? String(pieces[0]) : ""
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !["guest", "anonymous"].contains(user.lowercased()),
              !account.contains("\0") else { throw SMBDriveError.credentialsRequired }
        self.endpoint = endpoint
        self.server = host + (parts.port.map { ":\($0)" } ?? "")
        self.share = share
        self.user = user
        self.domain = domain
        self.security = security
    }

    static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    /// Treat paths as literal SMB names, never percent-decode or standardize traversal away.
    static func relativePath(_ path: String) throws -> String {
        guard !path.contains("\\"), !path.contains("\0"), !path.hasPrefix("//") else { throw SMBDriveError.invalidPath }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { throw SMBDriveError.invalidPath }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

nonisolated struct SMBFileInfo: Sendable, Equatable {
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modified: Date?
}

/// The transport serializes its context and bounds each blocking network operation.
nonisolated protocol SMBReadSession: Sendable {
    func connect() async throws
    func list(_ path: String) async throws -> [SMBFileInfo]
    func info(_ path: String) async throws -> SMBFileInfo
    func read(_ path: String, range: Range<Int64>) async throws -> Data
    func disconnect() async
    var supportsReviewedDeletion: Bool { get }
    func reviewDeletion(_ path: String) async throws -> RemoteEntry
    func inspectionSnapshot(_ path: String) async throws -> any RemoteInspectionSnapshot
    func deleteReviewed(_ entry: RemoteEntry, authorized: @escaping @MainActor @Sendable () -> Bool) async throws
    func copyVerified(_ path: String, to destination: URL, expectedBytes: Int64?,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> Int64
}

nonisolated extension SMBReadSession {
    var supportsReviewedDeletion: Bool { false }
    func reviewDeletion(_ path: String) async throws -> RemoteEntry { throw RemoteWriteError.unsupported }
    func inspectionSnapshot(_ path: String) async throws -> any RemoteInspectionSnapshot { throw RemoteWriteError.unsupported }
    func deleteReviewed(_ entry: RemoteEntry, authorized: @escaping @MainActor @Sendable () -> Bool) async throws {
        throw RemoteWriteError.unsupported
    }
    func copyVerified(_ path: String, to destination: URL, expectedBytes: Int64?,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        throw SMBDriveError.unavailableOnPlatform
    }
}

/// SMB2/3 reads and reviewed exact-file deletion. Tag replacement remains unsupported.
public actor SMBDrive: RemoteDeletionDrive, ResumableRemoteFileDrive {
    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let share: String
    public nonisolated let security: SMBSecurityPolicy
    public nonisolated let capabilities: RemoteCapabilities
    /// Each metadata/media bridge request stays bounded; large media downloads stream in chunks.
    public nonisolated static let maximumReadBytes: Int64 = 8 * 1024 * 1024
    public nonisolated static let maximumDownloadBytes: Int64 = 64 * 1024 * 1024
    private let session: any SMBReadSession

    public init(endpoint: URL, share: String, account: String, password: String, sourceID: String,
                displayName: String? = nil, security: SMBSecurityPolicy = .encrypted) throws {
        let settings = try SMBConnectionSettings(endpoint: endpoint, share: share, account: account, security: security)
        guard !password.isEmpty, !password.contains("\0") else { throw SMBDriveError.credentialsRequired }
        #if os(iOS) || os(macOS) || os(tvOS)
        session = SMBCSession(settings: settings, password: password)
        #else
        throw SMBDriveError.unavailableOnPlatform
        #endif
        id = sourceID
        self.displayName = displayName ?? endpoint.host() ?? "Music server"
        self.share = share
        self.security = security
        capabilities = session.supportsReviewedDeletion ? [.read, .ranges, .delete] : [.read, .ranges]
    }

    init(settings: SMBConnectionSettings, sourceID: String, session: any SMBReadSession) {
        id = sourceID
        displayName = settings.endpoint.host() ?? "Music server"
        share = settings.share
        security = settings.security
        self.session = session
        capabilities = session.supportsReviewedDeletion ? [.read, .ranges, .delete] : [.read, .ranges]
    }

    public func connect() async throws { try await session.connect() }
    public func disconnect() async { await session.disconnect() }

    public func reviewDeletion(_ path: String) async throws -> RemoteEntry {
        let relative = try SMBConnectionSettings.relativePath(path)
        guard !relative.isEmpty, path == "/" + relative else { throw SMBDriveError.invalidPath }
        return try await session.reviewDeletion(relative)
    }

    public func inspectionSnapshot(_ path: String) async throws -> any RemoteInspectionSnapshot {
        let relative = try SMBConnectionSettings.relativePath(path)
        guard !relative.isEmpty, path == "/" + relative else { throw SMBDriveError.invalidPath }
        return try await session.inspectionSnapshot(relative)
    }

    public func deleteReviewed(_ entry: RemoteEntry, authorized: @escaping @MainActor @Sendable () -> Bool) async throws {
        let relative = try SMBConnectionSettings.relativePath(entry.path)
        guard !relative.isEmpty, entry.path == "/" + relative, !entry.isDirectory,
              entry.version?.hasPrefix("smb-delete-v1:") == true else { throw RemoteWriteError.changed }
        try await session.deleteReviewed(entry, authorized: authorized)
    }

    public func copyVerified(_ path: String, to checkpoint: URL, expectedBytes: Int64?,
                             progress: @escaping @Sendable (Double) async -> Void) async throws -> Int64 {
        let relative = try SMBConnectionSettings.relativePath(path)
        try Task.checkCancellation()
        let updates = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let relay = Task { for await fraction in updates.stream { await progress(fraction) } }
        do {
            let size = try await session.copyVerified(relative, to: checkpoint, expectedBytes: expectedBytes) { fraction in
                updates.continuation.yield(fraction)
            }
            updates.continuation.finish()
            await relay.value
            try Task.checkCancellation()
            return size
        } catch {
            updates.continuation.finish()
            await relay.value
            throw error
        }
    }

    public func roots() async throws -> [RemoteEntry] {
        try Task.checkCancellation()
        try await session.connect()
        try Task.checkCancellation()
        return [RemoteEntry(path: "/", name: share, isDirectory: true, size: nil, modified: nil)]
    }

    public func list(_ path: String) async throws -> [RemoteEntry] {
        let relative = try SMBConnectionSettings.relativePath(path)
        try Task.checkCancellation()
        let entries = try await session.list(relative)
        try Task.checkCancellation()
        var seen = Set<String>()
        return try entries.filter { $0.name != "." && $0.name != ".." && !$0.isSymbolicLink }.map { file in
            guard SMBConnectionSettings.validComponent(file.name), seen.insert(file.name).inserted else { throw SMBDriveError.invalidResponse }
            let path = "/" + (relative.isEmpty ? "" : relative + "/") + file.name
            return RemoteEntry(path: path, name: file.name, isDirectory: file.isDirectory,
                               size: file.isDirectory ? nil : file.size, modified: file.modified)
        }.sorted { $0.path < $1.path }
    }

    public func info(_ path: String) async throws -> RemoteEntry {
        let relative = try SMBConnectionSettings.relativePath(path)
        try Task.checkCancellation()
        let file = try await session.info(relative)
        try Task.checkCancellation()
        guard !file.isSymbolicLink else { throw SMBDriveError.invalidPath }
        return RemoteEntry(path: relative.isEmpty ? "/" : "/" + relative,
                           name: relative.isEmpty ? share : (relative as NSString).lastPathComponent,
                           isDirectory: file.isDirectory, size: file.isDirectory ? nil : file.size, modified: file.modified)
    }

    public func read(_ path: String, range: Range<Int64>) async throws -> Data {
        let relative = try SMBConnectionSettings.relativePath(path)
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
              range.upperBound - range.lowerBound <= Self.maximumReadBytes else { throw RemoteDriveError.tooLarge }
        try Task.checkCancellation()
        if range.isEmpty { return Data() }
        let data = try await session.read(relative, range: range)
        try Task.checkCancellation()
        guard data.count <= range.count else { throw SMBDriveError.invalidResponse }
        return data
    }

    public func download(_ path: String, maxBytes: Int64) async throws -> Data {
        guard maxBytes >= 0 else { throw RemoteDriveError.tooLarge }
        let limit = min(maxBytes, Self.maximumDownloadBytes)
        let metadata = try await info(path)
        guard !metadata.isDirectory, let size = metadata.size, size >= 0, size <= limit else { throw RemoteDriveError.tooLarge }
        var result = Data()
        while Int64(result.count) < size {
            try Task.checkCancellation()
            let start = Int64(result.count)
            let end = start + min(Self.maximumReadBytes, size - start)
            let bytes = try await read(path, range: start..<end)
            guard !bytes.isEmpty else { throw SMBDriveError.invalidResponse }
            result.append(bytes)
        }
        // Covers may be replaced during a read. Never return a silently truncated or mixed generation.
        let after = try await info(path)
        guard after.size == metadata.size, after.modified == metadata.modified else { throw SMBDriveError.invalidResponse }
        return result
    }

    public nonisolated func streamURL(for path: String) -> URL? { nil }
}

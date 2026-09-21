import Foundation

public nonisolated struct DownloadAuthentication: Codable, Sendable {
    public let origin: NASOrigin
    public let account: String
    public let keychainAccount: String

    public init(origin: NASOrigin, account: String, keychainAccount: String) {
        self.origin = origin; self.account = account; self.keychainAccount = keychainAccount
    }

    /// Background redirects may be performed by the OS; they must never extend credential scope.
    public func permits(_ space: URLProtectionSpace, original: URL?, current: URL?, failures: Int) -> Bool {
        guard failures == 0, origin.isHTTPS, original != nil, original == current,
              original.flatMap(NASOrigin.init(url:)) == origin,
              current.flatMap(NASOrigin.init(url:)) == origin,
              !space.isProxy(), space.protocol?.lowercased() == "https",
              space.host.lowercased() == origin.host, space.port == origin.port else { return false }
        return [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod)
    }
}

public nonisolated enum RemoteDownloadSource: Sendable {
    case http(URLRequest, DownloadAuthentication)
    case file(drive: any RemoteFileDrive, path: String)
}

/// Implementations must verify every persisted prefix byte against one protected representation
/// before appending. Merely comparing size/mtime does not satisfy this contract.
public nonisolated protocol ResumableRemoteFileDrive: RemoteFileDrive {
    func copyVerified(_ path: String, to checkpoint: URL, expectedBytes: Int64?,
                      progress: @escaping @Sendable (Double) async -> Void) async throws -> Int64
}

nonisolated enum ForegroundFileTransfer {
    @concurrent static func copy(drive: any RemoteFileDrive, path: String, destination: URL, expectedBytes: Int64?,
                     checkpoint: URL? = nil, progress: @escaping @Sendable (Double) async -> Void) async throws -> Int64 {
        if let checkpoint, let resumable = drive as? any ResumableRemoteFileDrive {
            let size = try await resumable.copyVerified(path, to: checkpoint, expectedBytes: expectedBytes, progress: progress)
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: checkpoint, to: destination)
            return size
        }
        let original = try await drive.info(path)
        guard !original.isDirectory, let size = original.size, size > 0,
              expectedBytes == nil || expectedBytes == size else { throw ProviderError.changed }
        // A resumed partial is only reused within the same running operation. After reconnect,
        // restart from zero because size and mtime alone cannot prove byte-for-byte identity.
        try Data().write(to: destination)
        let handle = try FileHandle(forWritingTo: destination)
        var complete = false
        defer { try? handle.close(); if !complete { try? FileManager.default.removeItem(at: destination) } }
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let upper = offset + min(1024 * 1024, size - offset)
            let data = try await drive.read(path, range: offset..<upper, matching: original)
            guard !data.isEmpty, Int64(data.count) <= upper - offset else { throw ProviderError.invalidResponse }
            try Task.checkCancellation()
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            await progress(Double(offset) / Double(size))
        }
        let current = try await drive.info(path)
        guard current.sameVersion(as: original) else { throw ProviderError.changed }
        try Task.checkCancellation()
        try handle.synchronize()
        complete = true
        return size
    }
}

/// Phone-to-Watch delivery uses a dedicated temporary copy, never the shared offline cache file.
public nonisolated enum WatchAudioPreparation {
    public static func copy(drive: any RemoteFileDrive, path: String, to destination: URL, expectedBytes: Int64) async throws -> Int64 {
        try await ForegroundFileTransfer.copy(drive: drive, path: path, destination: destination, expectedBytes: expectedBytes) { _ in }
    }
}

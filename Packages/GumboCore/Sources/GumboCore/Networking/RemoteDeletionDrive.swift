import Foundation

/// Deletion is independent of upload/tag replacement. A provider must enforce its own
/// reviewed-file condition; generic protocol headers do not establish this capability.
public nonisolated protocol RemoteDeletionDrive: RemoteFileDrive {
    /// Reads a deletion validator and checks this account's permissions without changing the file.
    func reviewDeletion(_ path: String) async throws -> RemoteEntry
    func inspectionSnapshot(_ path: String) async throws -> any RemoteInspectionSnapshot
    /// Deletes only the reviewed representation, checking current authority after network preparation.
    func deleteReviewed(_ entry: RemoteEntry, authorized: @escaping @MainActor @Sendable () -> Bool) async throws
}

public nonisolated extension WritableRemoteDrive {
    func reviewDeletion(_ path: String) async throws -> RemoteEntry { try await info(path) }

    /// Existing DSM staging semantics. Providers needing stronger conditions implement their own witness.
    func deleteReviewed(_ entry: RemoteEntry, authorized: @escaping @MainActor @Sendable () -> Bool) async throws {
        guard capabilities.contains(.delete) else { throw RemoteWriteError.unsupported }
        let current = try await info(entry.path)
        guard !entry.isDirectory, current == entry else { throw RemoteWriteError.changed }
        try Task.checkCancellation()
        guard await authorized() else { throw CancellationError() }
        try await delete(entry.path)
    }
}

import Foundation

/// Bounded reads of the representation being classified, with an explicit lifetime. Providers
/// with protected handles retain them until close; legacy providers revalidate each read.
public nonisolated protocol RemoteInspectionSnapshot: Sendable {
    var entry: RemoteEntry { get }
    func read(_ range: Range<Int64>) async throws -> Data
    func validate() async throws
    func close() async
}

public nonisolated extension RemoteDeletionDrive {
    func inspectionSnapshot(_ path: String) async throws -> any RemoteInspectionSnapshot {
        VersionedInspectionSnapshot(drive: self, entry: try await reviewDeletion(path))
    }
}

private nonisolated struct VersionedInspectionSnapshot: RemoteInspectionSnapshot {
    let drive: any RemoteDeletionDrive
    let entry: RemoteEntry
    func read(_ range: Range<Int64>) async throws -> Data {
        try await drive.read(entry.path, range: range, matching: entry)
    }
    func validate() async throws {
        guard try await drive.reviewDeletion(entry.path) == entry else { throw RemoteWriteError.changed }
    }
    func close() async {}
}

/// The structural inspector can only access the single reviewed file, not another path.
nonisolated struct InspectionSnapshotDrive: RemoteFileDrive {
    let id: String
    let displayName: String
    let snapshot: any RemoteInspectionSnapshot
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func streamURL(for path: String) -> URL? { nil }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { throw RemoteWriteError.unsupported }
    func info(_ path: String) async throws -> RemoteEntry {
        guard path == snapshot.entry.path else { throw RemoteWriteError.changed }
        try await snapshot.validate()
        return snapshot.entry
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        guard path == snapshot.entry.path else { throw RemoteWriteError.changed }
        return try await snapshot.read(range)
    }
}

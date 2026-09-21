import Foundation

/// Resumable bytes are hidden from completed-download discovery. The descriptor is scope only;
/// it never proves remote file identity. The provider must verify the bytes against a new open.
nonisolated struct ForegroundDownloadCheckpoint {
    struct Scope: Codable, Equatable, Sendable {
        var version = 1
        let sourceID: String
        let path: String
        let profileID: String
        let accessEpoch: String
        let deletionEpoch: String?
    }
    let directory: URL
    init(cacheDirectory: URL) { directory = cacheDirectory.appending(path: ".foreground-checkpoints", directoryHint: .isDirectory) }

    func prepare(key: String, scope: Scope) throws -> URL {
        guard key.count == 64, key.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw SMBDriveError.invalidPath }
        try ensureDirectory(directory)
        let folder = directory.appending(path: key, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) { try ensureDirectory(folder) }
        let descriptor = folder.appending(path: "scope.json")
        let previous = CheckpointFileIO.descriptor(descriptor).flatMap { try? JSONDecoder().decode(Scope.self, from: $0) }
        if previous != scope { try? FileManager.default.removeItem(at: folder) }
        try ensureDirectory(folder)
        if previous != scope { try JSONEncoder().encode(scope).write(to: descriptor, options: .atomic) }
        let file = folder.appending(path: "payload.partial")
        let handle = try CheckpointFileIO.payload(file)
        try handle.close()
        return file
    }

    func remove(key: String) {
        guard key.count == 64, key.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return }
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: key))
    }
    func removeAll() { try? FileManager.default.removeItem(at: directory) }

    func retainedBytes(excluding keys: Set<String>) -> Int64 {
        guard let folders = safeFolders() else { return 0 }
        return folders.filter { !keys.contains($0.lastPathComponent) }.reduce(0) { total, folder in
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let bytes = CheckpointFileIO.size(folder.appending(path: "payload.partial")) else { return total }
            return total > Int64.max - bytes ? Int64.max : total + bytes
        }
    }

    func prune(keeping keys: Set<String>) -> Int {
        guard let folders = safeFolders() else { return 0 }
        var count = 0
        for folder in folders where !keys.contains(folder.lastPathComponent) {
            do { try FileManager.default.removeItem(at: folder); count += 1 } catch { }
        }
        return count
    }

    private func safeFolders() -> [URL]? {
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        return try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func ensureDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw SMBDriveError.invalidPath }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
    }
}
